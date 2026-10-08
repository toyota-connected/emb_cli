import 'dart:io';

import 'package:emb_cli/src/cross/cross_arch.dart';
import 'package:emb_cli/src/cross/elf_check.dart';
import 'package:emb_cli/src/cross/process_runner.dart';
import 'package:path/path.dart' as p;

/// Thrown when vendoring cannot be trusted to have seen the whole closure.
class FlatpakVendorException implements Exception {
  FlatpakVendorException(this.message);
  final String message;
  @override
  String toString() => 'FlatpakVendorException: $message';
}

/// A staged library needing a symbol version that the runtime's own copy of the
/// library named by `from` does not define — `libfoo.so.1` wanting
/// `GLIBC_2.38` from a `libc.so.6` that stops at 2.36. The loader reports it as
/// `version 'X' not found` and the app dies at startup inside the sandbox.
typedef SymbolVersionGap = ({String staged, String from, String version});

/// What a vendoring pass did, for the log and for tests.
class VendorReport {
  const VendorReport({
    required this.staged,
    required this.provided,
    required this.unresolved,
    this.symbolGaps = const [],
  });

  /// Sonames copied into the bundle's `lib/`, sorted.
  final List<String> staged;

  /// Sonames the runtime already provides, so they were left alone. Sorted.
  final List<String> provided;

  /// Sonames neither the runtime nor the search paths could account for.
  final List<String> unresolved;

  /// Staged libraries whose symbol-version requirements the runtime cannot
  /// satisfy. Sorted. Advisory: the arch check is a hard skip because a
  /// wrong-arch library is never usable, while this one compares against a
  /// runtime that was probed, with a `readelf` that may not have read it.
  final List<SymbolVersionGap> symbolGaps;
}

/// Fills the gap between a sysroot and a flatpak runtime.
class FlatpakLibVendor {
  FlatpakLibVendor({
    required this.readelf,
    required this.triple,
    ProcessRunner runProcess = defaultProcessRunner,
    Map<String, String> environment = const {},
  }) : _run = runProcess,
       _env = environment;

  /// Path to a `readelf` that understands [triple] (the cross binutils one).
  final String readelf;

  /// Target triple, used to reject a host-arch library found on a search path.
  final String triple;

  final ProcessRunner _run;
  final Map<String, String> _env;

  /// The soname the dynamic loader itself provides; never a file on disk.
  static const _vdso = 'linux-vdso.so.1';

  /// A shared object's file name: `libfoo.so`, `libfoo.so.1`, `libfoo.so.1.2`.
  /// Anchored, so `notes.sock` and `libfoo.solib` are not mistaken for one.
  static final _soName = RegExp(r'\.so(\.\d+)*$');

  /// Vendor into `<bundleDir>/lib`, seeded from [command] plus every shared
  /// object already there. [runtimeFiles] is the runtime's `files/` tree (from
  /// `flatpak info --show-location`); [searchPaths] are the directories a
  /// missing soname is looked up in, normally the target sysroot's lib dirs.
  Future<VendorReport> vendor({
    required Directory bundleDir,
    required String command,
    required Directory runtimeFiles,
    required List<Directory> searchPaths,
  }) async {
    final libDir = Directory(p.join(bundleDir.path, 'lib'));
    final provided = <String>[];
    final staged = <String>[];
    final unresolved = <String>[];

    // Anything already in the bundle is, by definition, already vendored.
    final present = <String>{
      if (libDir.existsSync())
        for (final e in libDir.listSync())
          if (e is File || e is Link) p.basename(e.path),
    };

    final embedder = File(p.join(bundleDir.path, command));
    if (await _needed(embedder) == null) {
      throw FlatpakVendorException(
        'could not read the dynamic section of ${embedder.path} with '
        '"$readelf" — the closure cannot be computed, so nothing would be '
        'vendored',
      );
    }

    final runtimeIndex = _indexRuntime(runtimeFiles);
    final seen = <String>{};
    final queue = <File>[
      embedder,
      if (libDir.existsSync())
        for (final e in libDir.listSync())
          if (e is File && _soName.hasMatch(p.basename(e.path))) e,
    ];

    while (queue.isNotEmpty) {
      final elf = queue.removeLast();
      for (final soname in await _needed(elf) ?? const <String>[]) {
        if (soname == _vdso || !seen.add(soname)) continue;
        // Bundle first: `$ORIGIN/lib` is searched ahead of the runtime's own paths.
        if (present.contains(soname)) continue;
        if (runtimeIndex.containsKey(soname)) {
          provided.add(soname);
          continue;
        }
        final src = _resolve(soname, searchPaths);
        if (src == null) {
          unresolved.add(soname);
          continue;
        }
        final dest = _stage(src, soname, libDir);
        present.add(soname);
        staged.add(soname);
        // A vendored library drags in its own closure.
        queue.add(dest);
      }
    }

    staged.sort();
    provided.sort();
    unresolved.sort();
    return VendorReport(
      staged: staged,
      provided: provided,
      unresolved: unresolved,
      symbolGaps: await _symbolGaps(staged, libDir, runtimeIndex),
    );
  }

  /// Staged libraries asking the runtime for symbol versions it does not
  /// define.
  ///
  /// The arch check in [_resolve] is the same class of problem one layer up: a
  /// library that resolves, links and then fails at load. It compares
  /// `e_machine` and word size, which a host library built against a newer
  /// glibc passes — and with `--target local` the search root falls back to
  /// `/`, so that is the ordinary case rather than a contrived one. The failure
  /// lands inside the sandbox at startup, a long way from the build.
  ///
  /// Membership, not a version comparison: the loader resolves a version by
  /// name, so a name the runtime's copy does not define is exactly what fails.
  /// That also handles the names no ordering applies to, such as
  /// `GLIBC_ABI_DT_RELR`.
  ///
  /// A runtime library that defines no versions at all is treated as unknown
  /// rather than as defining none, so an unversioned library — or output this
  /// did not parse — does not turn every requirement into a warning.
  ///
  /// Only requirements aimed at a library the *runtime* provides are checked. A
  /// requirement on a library vendored alongside is satisfied by the copy that
  /// shipped with it, and one on a library nothing provides is already reported
  /// as unresolved.
  Future<List<SymbolVersionGap>> _symbolGaps(
    List<String> staged,
    Directory libDir,
    Map<String, File> runtimeIndex,
  ) async {
    final gaps = <SymbolVersionGap>[];
    final defsCache = <String, Set<String>?>{};

    Future<Set<String>?> definedBy(String soname) async {
      if (defsCache.containsKey(soname)) return defsCache[soname];
      final file = runtimeIndex[soname];
      Set<String>? defs;
      if (file != null) {
        final r = await _run(readelf, ['-V', file.path], environment: _env);
        // Two ways to learn nothing, both treated as nothing: a readelf that
        // could not read the file, and a file with no version definitions at
        // all. Comparing against an empty set would report every requirement
        // as a gap — which is the wrong answer whether the library is
        // genuinely unversioned or the output simply did not parse.
        if (r.exitCode == 0) {
          final parsed = parseVersionDefs(r.stdout);
          if (parsed.isNotEmpty) defs = parsed;
        }
      }
      return defsCache[soname] = defs;
    }

    for (final soname in staged) {
      final file = File(p.join(libDir.path, soname));
      final r = await _run(readelf, ['-V', file.path], environment: _env);
      if (r.exitCode != 0) continue;
      final needs = parseVersionNeeds(r.stdout);
      for (final entry in needs.entries) {
        if (!runtimeIndex.containsKey(entry.key)) continue;
        final defs = await definedBy(entry.key);
        if (defs == null) continue;
        for (final version in entry.value) {
          if (!defs.contains(version)) {
            gaps.add((staged: soname, from: entry.key, version: version));
          }
        }
      }
    }
    gaps.sort((a, b) {
      final s = a.staged.compareTo(b.staged);
      if (s != 0) return s;
      final f = a.from.compareTo(b.from);
      return f != 0 ? f : a.version.compareTo(b.version);
    });
    return gaps;
  }

  /// `DT_NEEDED` sonames of [elf], or null when readelf could not read it — a
  /// missing file, a non-ELF, or a broken tool. An empty list means the file
  /// was read and needs nothing, which is a different thing entirely.
  Future<List<String>?> _needed(File elf) async {
    if (!elf.existsSync()) return null;
    final r = await _run(readelf, ['-d', elf.path], environment: _env);
    if (r.exitCode != 0) return null;
    return parseNeededSonames(r.stdout);
  }

  /// Every library the runtime ships, by basename, so a soname lookup is a map
  /// hit rather than a filesystem walk per query. Walks `lib`, `lib64` and
  /// `usr/lib` recursively, which covers the multiarch subdirectory wherever a
  /// given runtime puts it.
  ///
  /// The path is kept, not just the name: the symbol-version check has to read
  /// the runtime's own copy of a library to learn which versions it defines.
  Map<String, File> _indexRuntime(Directory runtimeFiles) {
    final names = <String, File>{};
    for (final rel in ['lib', 'lib64', 'usr/lib']) {
      final d = Directory(p.join(runtimeFiles.path, rel));
      if (!d.existsSync()) continue;
      try {
        for (final e in d.listSync(recursive: true, followLinks: false)) {
          final base = p.basename(e.path);
          // First wins: lib64 is commonly a symlink to lib, and either copy
          // answers the same question.
          if (e is File && _soName.hasMatch(base)) {
            names.putIfAbsent(base, () => e);
          }
        }
      } on FileSystemException {
        // Unreadable corner of the runtime tree: index what we can.
      }
    }
    return names;
  }

  File? _resolve(String soname, List<Directory> searchPaths) {
    final mad = debianMultiarch(triple);
    for (final dir in searchPaths) {
      for (final candidate in [
        File(p.join(dir.path, soname)),
        File(p.join(dir.path, mad, soname)),
      ]) {
        if (!candidate.existsSync()) continue;
        final real = File(candidate.resolveSymbolicLinksSync());
        // A host-arch library on a search path is worse than none: it links and
        // then fails at load. Skip it and let it show up as unresolved.
        if (verifyElfForTriple(real, triple) != null) continue;
        return real;
      }
    }
    return null;
  }

  /// Copy [src] in under its real basename and, when the soname differs, add
  /// the soname symlink beside it.
  File _stage(File src, String soname, Directory libDir) {
    libDir.createSync(recursive: true);
    final realName = p.basename(src.path);
    final dest = File(p.join(libDir.path, realName));
    if (!dest.existsSync()) src.copySync(dest.path);
    if (realName != soname) {
      final link = Link(p.join(libDir.path, soname));
      if (!link.existsSync()) link.createSync(realName);
    }
    return dest;
  }
}

/// A resolved vendoring pass: the tool, the runtime to subtract, and the
/// directories a missing soname is looked up in. Bound together so the
/// packager's `onStaged` hook takes one object rather than three values.
class FlatpakVendorPlan {
  const FlatpakVendorPlan({
    required this.vendor,
    required this.runtimeFiles,
    required this.searchPaths,
  });

  /// The vendoring tool, configured for the target's readelf and triple.
  final FlatpakLibVendor vendor;

  /// The runtime's `files/` tree: what the app does not need to ship.
  final Directory runtimeFiles;

  /// Where a soname the runtime lacks is looked up, normally the target
  /// sysroot's lib dirs.
  final List<Directory> searchPaths;

  /// Vendor into [bundleDir], seeding the closure from [command].
  Future<VendorReport> run({
    required Directory bundleDir,
    required String command,
  }) => vendor.vendor(
    bundleDir: bundleDir,
    command: command,
    runtimeFiles: runtimeFiles,
    searchPaths: searchPaths,
  );
}
