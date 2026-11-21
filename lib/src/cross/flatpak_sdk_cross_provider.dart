import 'dart:io';

import 'package:emb_cli/src/cross/cross_arch.dart';
import 'package:emb_cli/src/cross/cross_keys.dart';
import 'package:emb_cli/src/cross/cross_profile.dart';
import 'package:emb_cli/src/cross/cross_provider.dart';
import 'package:emb_cli/src/cross/cross_target.dart';
import 'package:emb_cli/src/cross/emb_lock.dart';
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
  }) : _run = runProcess ?? defaultProcessRunner,
       _emitter = emitter;

  final CrossTarget target;
  final Workspace workspace;
  final HostInfo host;
  final ProcessRunner _run;
  final ToolchainEmitter _emitter;

  @override
  String get name => 'flatpak-sdk';

  /// Names the working dirs and the architecture; the compiler's own triple
  /// is read from the SDK. Distinct from the `local` build's
  /// `<arch>-linux-gnu`, so the two never share an overlay.
  @override
  String get triple =>
      target.targetTriple ?? '${host.machineArch}-flatpak-linux-gnu';

  @override
  List<String> get preflightTools => const [
    'flatpak',
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
  String get sdkRef {
    final fp = target.package?.flatpak ?? const FlatpakPackageSpec();
    return '${fp.sdk}/${flatpakArch(triple)}/${fp.runtimeVersion}';
  }

  @override
  Future<CrossResolveResult> resolve() async {
    if (host.os != HostOs.linux) {
      return CrossResolveResult.unavailable(
        'flatpak-sdk needs a Linux host; host is ${host.os.name}',
      );
    }
    final ref = sdkRef;
    final loc = await _flatpakInfo('--show-location', ref);
    if (loc == null) {
      return CrossResolveResult.unavailable(
        '$ref is not installed. Install it from its remote, e.g. '
        '`flatpak install flathub $ref`',
      );
    }
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
    final commit = await _flatpakInfo('--show-commit', ref);

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
    );
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
