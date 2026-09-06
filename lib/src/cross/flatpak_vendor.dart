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

/// What a vendoring pass did, for the log and for tests.
class VendorReport {
  const VendorReport({
    required this.staged,
    required this.provided,
    required this.unresolved,
  });

  /// Sonames copied into the bundle's `lib/`, sorted.
  final List<String> staged;

  /// Sonames the runtime already provides, so they were left alone. Sorted.
  final List<String> provided;

  /// Sonames neither the runtime nor the search paths could account for.
  final List<String> unresolved;
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
          if (e is File && p.basename(e.path).contains('.so')) e,
    ];

    while (queue.isNotEmpty) {
      final elf = queue.removeLast();
      for (final soname in await _needed(elf) ?? const <String>[]) {
        if (soname == _vdso || !seen.add(soname)) continue;
        // Bundle first: `$ORIGIN/lib` is searched ahead of the runtime's own paths.
        if (present.contains(soname)) continue;
        if (runtimeIndex.contains(soname)) {
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
    );
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

  /// Every library basename the runtime ships, so a soname lookup is a set hit
  /// rather than a filesystem walk per query. Walks `lib`, `lib64` and
  /// `usr/lib` recursively, which covers the multiarch subdirectory wherever a
  /// given runtime puts it.
  Set<String> _indexRuntime(Directory runtimeFiles) {
    final names = <String>{};
    for (final rel in ['lib', 'lib64', 'usr/lib']) {
      final d = Directory(p.join(runtimeFiles.path, rel));
      if (!d.existsSync()) continue;
      try {
        for (final e in d.listSync(recursive: true, followLinks: false)) {
          final base = p.basename(e.path);
          if (base.contains('.so')) names.add(base);
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
