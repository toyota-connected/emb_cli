import 'dart:io';

import 'package:emb_cli/src/cache/cache_dir.dart';
import 'package:emb_cli/src/cross/cross_arch.dart';
import 'package:emb_cli/src/cross/cross_keys.dart';
import 'package:emb_cli/src/cross/cross_profile.dart';
import 'package:emb_cli/src/cross/cross_provider.dart';
import 'package:emb_cli/src/cross/cross_target.dart';
import 'package:emb_cli/src/cross/emb_lock.dart';
import 'package:emb_cli/src/cross/flatpak_sdk_repo.dart';
import 'package:emb_cli/src/cross/process_runner.dart';
import 'package:emb_cli/src/cross/toolchain_emitter.dart';
import 'package:emb_cli/src/host/host_info.dart';
import 'package:emb_cli/src/workspace/workspace.dart';
import 'package:path/path.dart' as p;

/// Builds against an installed flatpak SDK, so the result links the
/// runtime's glibc and libstdc++ rather than the host's (#335).
///
/// The SDK is `package.flatpak.sdk` at the `runtime_version` branch, for the
/// architecture of [triple], found with `flatpak info --show-location`. Its
/// `files/` is what the sandbox mounts at `/usr`, so a sysroot is a directory
/// of symlinks: `usr` to `files`, and `lib`, `bin` (and `lib64`, `sbin`
/// when present) into it. The SDK itself is never written to; augments go to
/// a separate overlay.
///
/// The SDK's own compiler doesn't run on the host (its binutils need the
/// SDK's libraries, and an aarch64 SDK's tools are aarch64 binaries), so the
/// compiler is the host clang, pointed at the SDK's gcc installation with
/// `--target=<the SDK's gcc triple>`. Linking needs lld: the SDK's `libc.so`
/// linker script names absolute `/usr/lib/...` paths, and bfd rebases them
/// only when the script's real path is inside the sysroot, which a symlinked
/// `usr` is not.
///
/// The SDK ships libraries its runtime does not, so the profile also names
/// the runtime's library dirs ([CrossProfile.runtimeLibDirs]): an augment the
/// SDK satisfies is still built when the runtime lacks one of its libraries.
///
/// The loader path comes from the SDK too. Clang's default
/// (`/lib64/ld-linux-x86-64.so.2`) is absent from a runtime with no `lib64`,
/// and a binary naming it fails to start with "No such file or directory".
class FlatpakSdkCrossProvider implements CrossProvider {
  FlatpakSdkCrossProvider(
    this.target, {
    required this.workspace,
    required this.host,
    ProcessRunner? runProcess,
    ToolchainEmitter emitter = const ToolchainEmitter(),
    this.manifestDir,
    this.offline = false,
    Directory? cacheDir,
  }) : _run = runProcess ?? defaultProcessRunner,
       _injectedRun = runProcess,
       _emitter = emitter,
       _cacheDirOverride = cacheDir;

  final CrossTarget target;
  final Workspace workspace;
  final HostInfo host;
  final ProcessRunner _run;
  final ProcessRunner? _injectedRun;
  final ToolchainEmitter _emitter;

  /// Collected while resolving, returned on the result.
  final _warnings = <String>[];

  /// What a relative `sdk_repo` / `sdk_repo_gpg_key` is relative to; the
  /// working directory when null.
  final Directory? manifestDir;

  /// With `sdk_repo`, pull nothing: the SDK and runtime must be in the cache.
  final bool offline;

  final Directory? _cacheDirOverride;

  FlatpakPackageSpec get _spec =>
      target.package?.flatpak ?? const FlatpakPackageSpec();

  /// `sdk_repo` as a URL, or a path made absolute; null without one.
  String? get repoSource {
    final v = _spec.sdkRepo;
    if (v == null || v.contains('://')) return v;
    return _absolute(v);
  }

  String? get _repoGpgKey {
    final v = _spec.sdkRepoGpgKey;
    return v == null ? null : _absolute(v);
  }

  String _absolute(String v) => p.isAbsolute(v)
      ? v
      : p.normalize(
          p.join((manifestDir ?? Directory.current).absolute.path, v),
        );

  /// A warning for an `sdk_repo` URL pulled with no signature check, or null.
  /// Whoever answers that URL chooses the compiler's sysroot; `emb.lock` pins
  /// the commit afterwards, but not the first pull.
  String? get unverifiedRepoWarning {
    final src = _spec.sdkRepo;
    if (src == null || !src.contains('://') || _spec.sdkRepoGpgKey != null) {
      return null;
    }
    return 'flatpak sdk_repo $src is pulled without a signature check — '
        'whoever answers it chooses the sysroot. Set sdk_repo_gpg_key.';
  }

  @override
  String get name => 'flatpak-sdk';

  /// Names the working dirs and the architecture; the compiler's own triple
  /// is read from the SDK. Distinct from the `local` build's
  /// `<arch>-linux-gnu`, so the two never share an overlay.
  @override
  String get triple =>
      target.targetTriple ?? '${host.machineArch}-flatpak-linux-gnu';

  @override
  List<String> get preflightTools => [
    if (_spec.sdkRepo != null) 'ostree' else 'flatpak',
    'clang',
    'clang++',
    'ld.lld',
    'llvm-ar',
    'llvm-strip',
    'llvm-readelf',
  ];

  @override
  List<({String kind, String key})> cacheSelectors() => const [];

  /// The SDK ref this target builds against, e.g.
  /// `org.freedesktop.Sdk/x86_64/25.08`.
  String get sdkRef =>
      '${_spec.sdk}/${flatpakArch(triple)}/${_spec.runtimeVersion}';

  /// Where [ref] is on disk and which commit, from the installation
  /// (`flatpak info`) or, with `sdk_repo`, from a checkout of that repo.
  /// Throws [_Unresolved] with the result to return.
  ///
  /// [forSdk] names the SDK when [ref] is the runtime it builds for.
  Future<({String path, String? commit})> _locate(
    String ref, {
    String? forSdk,
  }) async {
    final source = repoSource;
    if (source != null) {
      try {
        final c = await _repo.checkout(
          source,
          'runtime/$ref',
          gpgKey: _repoGpgKey,
        );
        if (c.warning case final w?) _warnings.add(w);
        return (path: c.path, commit: c.commit);
      } on FlatpakSdkRepoException catch (e) {
        throw _Unresolved(CrossResolveResult.failed(e.message));
      }
    }
    final loc = await _flatpakInfo('--show-location', ref);
    if (loc == null) {
      throw _Unresolved(
        CrossResolveResult.unavailable(
          '${forSdk == null ? ref : '$ref, the runtime $forSdk builds for,'} '
          'is not installed. Install it from its remote, e.g. '
          '`flatpak install flathub $ref`',
        ),
      );
    }
    return (path: loc, commit: await _flatpakInfo('--show-commit', ref));
  }

  late final FlatpakSdkRepo _repo = FlatpakSdkRepo(
    Directory(
      p.join((_cacheDirOverride ?? ensureCacheDir()).path, 'flatpak-sdk'),
    ),
    // Only the repo's pull takes a time limit, and only the timed runner can
    // kill a child that overruns. A test's runner is used as is.
    runProcess: switch (_injectedRun) {
      null => defaultTimedProcessRunner,
      final run => _untimed(run),
    },
    offline: offline,
  );

  static TimedProcessRunner _untimed(ProcessRunner run) =>
      (
        executable,
        arguments, {
        workingDirectory,
        environment,
        includeParentEnvironment = true,
        runInShell = false,
        output = ProcessOutputMode.capture,
        label,
        timeout,
      }) => run(
        executable,
        arguments,
        workingDirectory: workingDirectory,
        environment: environment,
        includeParentEnvironment: includeParentEnvironment,
        runInShell: runInShell,
        output: output,
        label: label,
      );

  @override
  Future<CrossResolveResult> resolve() async {
    if (host.os != HostOs.linux) {
      return CrossResolveResult.unavailable(
        'flatpak-sdk needs a Linux host; host is ${host.os.name}',
      );
    }
    final ref = sdkRef;
    _warnings.clear();
    try {
      return await _resolve(ref);
    } on _Unresolved catch (u) {
      return u.result;
    }
  }

  Future<CrossResolveResult> _resolve(String ref) async {
    final (path: loc, :commit) = await _locate(ref);
    final files = Directory(p.join(loc, 'files'));
    if (!files.existsSync()) {
      return CrossResolveResult.failed(
        '$ref: no files/ under $loc — is the install complete?',
      );
    }
    final FlatpakSdkLayout layout;
    try {
      layout = FlatpakSdkLayout.probe(files, flatpakArch(triple));
    } on FormatException catch (e) {
      return CrossResolveResult.failed('$ref: ${e.message}');
    } on FileSystemException catch (e) {
      return CrossResolveResult.failed('$ref: ${e.message}: ${e.path}');
    }

    // The runtime the SDK pairs with, which is what the app runs on. The SDK
    // ships libraries the runtime does not, so whether an augment is already
    // provided is asked of the runtime, not the SDK.
    final runtimeRef = runtimeRefOf(File(p.join(loc, 'metadata')));
    if (runtimeRef == null) {
      return CrossResolveResult.failed(
        '$ref: its metadata names no runtime',
      );
    }
    final (path: runtimeLoc, commit: _) = await _locate(
      runtimeRef,
      forSdk: ref,
    );
    final runtimeFiles = p.join(runtimeLoc, 'files');
    final runtimeLibDirs = [
      for (final d in {layout.libDir, 'lib'})
        if (Directory(p.join(runtimeFiles, d)).existsSync())
          p.join(runtimeFiles, d),
    ];

    // Where `emb cross --clean --all` looks. Deleting it removes the links,
    // never the SDK they point into.
    final dir = workspace.ensurePlatformDir(
      'cross-$triple-${sysrootKey(target)}',
    );
    final Directory sysroot;
    try {
      sysroot = linkSysroot(Directory(p.join(dir.path, 'sysroot')), files);
    } on FileSystemException catch (e) {
      // A real directory where a link belongs, or a second emb relinking
      // the same sysroot at once.
      return CrossResolveResult.failed(
        'could not link the sysroot to $ref: ${e.message}: ${e.path}',
      );
    }

    final cpuFlags = [...target.cpuFlags, '--target=${layout.gccTriple}'];
    final linkFlags = ['-fuse-ld=lld', '-Wl,--dynamic-linker=${layout.loader}'];
    const tools = (
      cc: 'clang',
      cxx: 'clang++',
      ar: 'llvm-ar',
      strip: 'llvm-strip',
    );
    // crossBin is only used for the prefix map; the compiler is the host's,
    // and mapping /usr/bin would rewrite unrelated recorded paths.
    final cmakeTc = _emitter.emitCMake(
      outDir: dir,
      triple: triple,
      crossBin: '',
      sysroot: sysroot.path,
      cpuFlags: cpuFlags,
      tools: tools,
      linkFlags: linkFlags,
    );
    final mesonCross = _emitter.emitMeson(
      outDir: dir,
      triple: triple,
      crossBin: '',
      sysroot: sysroot.path,
      cpuFlags: cpuFlags,
      tools: tools,
      linkFlags: linkFlags,
    );

    final usr = p.join(sysroot.path, 'usr');
    final profile = CrossProfile(
      providerName: name,
      targetTriple: triple,
      cc: tools.cc,
      cxx: tools.cxx,
      ar: tools.ar,
      strip: tools.strip,
      targetSysroot: sysroot.path,
      cFlags: cpuFlags,
      cxxFlags: cpuFlags,
      ldFlags: linkFlags,
      pkgConfig: PkgConfig(
        sysrootDir: sysroot.path,
        libdir: [
          p.join(usr, layout.libDir, 'pkgconfig'),
          if (layout.libDir != 'lib') p.join(usr, 'lib', 'pkgconfig'),
          p.join(usr, 'share', 'pkgconfig'),
        ],
      ),
      cmakeToolchainFile: cmakeTc,
      mesonCrossFile: mesonCross,
      // The SDK is not ours to stage into.
      separateOverlay: true,
      runtimeLibDirs: runtimeLibDirs,
    );
    return CrossResolveResult.ok(
      profile,
      lockEntry: LockedTarget(
        provider: name,
        triple: triple,
        // A new SDK commit is a new glibc/libstdc++/library set: drift.
        toolchainVersion: commit == null ? ref : '$ref@$commit',
        compilerVersion: layout.gccVersion,
        sysrootKey: sysrootKey(target),
        buildKey: buildKey(target),
      ),
      warnings: List.unmodifiable(_warnings),
    );
  }

  /// The `runtime` ref in a flatpak `metadata` file's `[Runtime]` group,
  /// e.g. `org.freedesktop.Platform/x86_64/25.08`; null when absent.
  static String? runtimeRefOf(File metadata) {
    final List<String> lines;
    try {
      lines = metadata.readAsLinesSync();
    } on Exception {
      return null;
    }
    var inRuntime = false;
    for (final raw in lines) {
      final line = raw.trim();
      if (line.startsWith('[')) {
        inRuntime = line == '[Runtime]';
      } else if (inRuntime) {
        // GKeyFile allows spaces around `=`; freedesktop's SDK writes them.
        final eq = line.indexOf('=');
        if (eq < 0 || line.substring(0, eq).trim() != 'runtime') continue;
        final v = line.substring(eq + 1).trim();
        return v.isEmpty ? null : v;
      }
    }
    return null;
  }

  /// `flatpak info <flag> <ref>`, trimmed; null when it fails or is empty.
  Future<String?> _flatpakInfo(String flag, String ref) async {
    final RunResult r;
    try {
      r = await _run('flatpak', ['info', flag, ref]);
    } on ProcessException {
      return null;
    }
    final out = r.stdout.trim();
    return r.exitCode == 0 && out.isNotEmpty ? out : null;
  }

  /// Point [root]'s links at [files], replacing any that point elsewhere (a
  /// previous SDK commit lives at a different path).
  static Directory linkSysroot(Directory root, Directory files) {
    root.createSync(recursive: true);
    void link(String name, String to) {
      final l = Link(p.join(root.path, name));
      if (l.existsSync()) {
        if (l.targetSync() == to) return;
        l.deleteSync();
      }
      l.createSync(to);
    }

    link('usr', files.path);
    link('lib', p.join('usr', 'lib'));
    link('bin', p.join('usr', 'bin'));
    for (final d in const ['lib64', 'sbin']) {
      final l = Link(p.join(root.path, d));
      if (Directory(p.join(files.path, d)).existsSync()) {
        link(d, p.join('usr', d));
      } else if (l.existsSync()) {
        l.deleteSync();
      }
    }
    return root;
  }
}

/// What a flatpak SDK's tree says about compiling against it.
class FlatpakSdkLayout {
  const FlatpakSdkLayout({
    required this.gccTriple,
    required this.gccVersion,
    required this.libDir,
    required this.loader,
  });

  /// Read the layout of the SDK whose `files/` is [files], for the flatpak
  /// architecture [arch] (`x86_64`, `aarch64`, …). Throws [FormatException]
  /// naming what is missing.
  ///
  /// The layouts differ between SDK builders: the freedesktop SDK keeps
  /// libraries in `lib/x86_64-linux-gnu` and its gcc under
  /// `lib/gcc/x86_64-unknown-linux-gnu`; a Yocto-built one uses plain `lib`
  /// and `x86_64-oe-linux`. So each is read rather than assumed.
  factory FlatpakSdkLayout.probe(Directory files, String arch) {
    final gccRoot = Directory(p.join(files.path, 'lib', 'gcc'));
    final triples = gccRoot.existsSync()
        ? (gccRoot
              .listSync()
              .whereType<Directory>()
              .map((d) => p.basename(d.path))
              .where((n) => n.startsWith('$arch-'))
              .toList()
            ..sort())
        : const <String>[];
    if (triples.isEmpty) {
      throw FormatException(
        'no $arch gcc installation under lib/gcc — is this an SDK (not a '
        'runtime) for $arch?',
      );
    }
    final gccTriple = triples.first;
    // Both go into the emitted CMake and Meson files, inside quotes.
    if (!_safeToken.hasMatch(gccTriple)) {
      throw FormatException('unexpected gcc triple "$gccTriple"');
    }
    final versions =
        Directory(p.join(gccRoot.path, gccTriple))
            .listSync()
            .whereType<Directory>()
            .map((d) => p.basename(d.path))
            .where((n) => RegExp(r'^\d').hasMatch(n))
            .toList()
          ..sort(_compareVersions);
    if (versions.isEmpty) {
      throw FormatException('no gcc version under lib/gcc/$gccTriple');
    }

    final libDir =
        [
          'lib/${debianMultiarch(arch)}',
          'lib64',
          'lib',
        ].firstWhere(
          (d) => File(p.join(files.path, d, 'libc.so')).existsSync(),
          orElse: () => throw const FormatException(
            'no libc.so in lib/<multiarch>, lib64 or lib',
          ),
        );

    return FlatpakSdkLayout(
      gccTriple: gccTriple,
      gccVersion: versions.last,
      libDir: libDir,
      loader: _loader(File(p.join(files.path, libDir, 'libc.so'))),
    );
  }

  /// The gcc target triple (`x86_64-unknown-linux-gnu`, `aarch64-oe-linux`).
  final String gccTriple;

  /// The newest gcc version installed for [gccTriple].
  final String gccVersion;

  /// The directory holding `libc.so`, relative to `files/`.
  final String libDir;

  /// The dynamic loader the SDK's glibc names, e.g.
  /// `/usr/lib/ld-linux-aarch64.so.1`.
  final String loader;

  /// The loader from `libc.so`'s linker script: glibc lists it as
  /// `AS_NEEDED ( <loader> )`, the same path its own binaries request.
  static String _loader(File libcSo) {
    final String text;
    try {
      text = libcSo.readAsStringSync();
    } on Exception {
      // FileSystemException, or a FormatException from a binary file.
      throw FormatException('${libcSo.path} is not a readable linker script');
    }
    // `)` ends the path even with no space before it: `AS_NEEDED (/lib/ld.so)`.
    final m = RegExp(
      r'AS_NEEDED\s*\(\s*(/[^\s)]*ld-linux[^\s)]*)',
    ).firstMatch(text);
    if (m == null) {
      throw FormatException(
        '${p.basename(libcSo.path)} names no ld-linux loader',
      );
    }
    final loader = m.group(1)!;
    if (!RegExp(r'^/[A-Za-z0-9_./+-]+$').hasMatch(loader)) {
      throw FormatException('unexpected loader path "$loader"');
    }
    return loader;
  }

  static final _safeToken = RegExp(r'^[A-Za-z0-9_.+-]+$');

  static int _compareVersions(String a, String b) {
    List<int> parts(String v) =>
        v.split('.').map((s) => int.tryParse(s) ?? 0).toList();
    final x = parts(a);
    final y = parts(b);
    for (var i = 0; i < x.length && i < y.length; i++) {
      if (x[i] != y[i]) return x[i].compareTo(y[i]);
    }
    return x.length.compareTo(y.length);
  }
}

/// A resolve that stopped early, carrying the result to return.
class _Unresolved implements Exception {
  const _Unresolved(this.result);
  final CrossResolveResult result;
}
