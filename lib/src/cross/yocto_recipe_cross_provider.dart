import 'dart:io';

import 'package:emb_cli/src/cross/cross_keys.dart';
import 'package:emb_cli/src/cross/cross_profile.dart';
import 'package:emb_cli/src/cross/cross_provider.dart';
import 'package:emb_cli/src/cross/cross_target.dart';
import 'package:emb_cli/src/cross/emb_lock.dart';
import 'package:emb_cli/src/cross/toolchain_emitter.dart';
import 'package:emb_cli/src/host/host_info.dart';
import 'package:emb_cli/src/workspace/workspace.dart';
import 'package:path/path.dart' as p;

/// Resolves a Yocto build-tree `recipe-sysroot` (the nitrogen8mm pattern).
///
/// Unlike a relocatable SDK, this points into a live OE build directory and
/// uses a recipe's staged sysroot directly: `recipe-sysroot` is a complete
/// cross dev sysroot and the sibling `recipe-sysroot-native` ships the
/// matching `aarch64-poky-linux` gcc. Nothing is downloaded; we locate the
/// newest recipe workdir, then emit our own CMake + Meson files (the build
/// tree carries no relocatable toolchain file the way an SDK does).
class YoctoRecipeCrossProvider implements CrossProvider {
  YoctoRecipeCrossProvider(
    this.target, {
    required this.workspace,
    required this.host,
    ToolchainEmitter emitter = const ToolchainEmitter(),
  }) : _emitter = emitter;

  final CrossTarget target;
  final Workspace workspace;
  final HostInfo host;
  final ToolchainEmitter _emitter;

  @override
  String get name => 'yocto-recipe';

  @override
  String get triple => target.targetTriple ?? 'aarch64-poky-linux';

  @override
  List<String> get preflightTools => const ['pkg-config'];

  @override
  List<({String kind, String key})> cacheSelectors() => const [];

  /// Default OE tuning when the manifest gives none — matches the i.MX8MM
  /// weston recipe's flags.
  static const _defaultCpuFlags = [
    '-march=armv8-a+crc+crypto',
    '-mbranch-protection=standard',
  ];

  @override
  Future<CrossResolveResult> resolve() async {
    final buildDir = target.yoctoBuild;
    final tuple = target.machineTuple;
    if (buildDir == null || tuple == null) {
      return const CrossResolveResult.unavailable(
        'yocto-recipe needs cross.yocto_build and cross.machine_tuple',
      );
    }

    final recipeRoot = Directory(
      p.join(buildDir, 'tmp', 'work', tuple, target.recipe),
    );
    if (!recipeRoot.existsSync()) {
      return CrossResolveResult.unavailable(
        '${target.recipe} not built under ${recipeRoot.path} — build it so it '
        'stages the dev sysroot, or point cross.yocto_build at the right tree',
      );
    }

    // Newest version dir under the recipe workdir.
    final versionDir = _newestChild(recipeRoot);
    if (versionDir == null) {
      return CrossResolveResult.failed(
        'no version dir under ${recipeRoot.path}',
      );
    }

    final sysroot = p.join(versionDir.path, 'recipe-sysroot');
    final nativeSysroot = p.join(versionDir.path, 'recipe-sysroot-native');
    final triple = target.targetTriple ?? 'aarch64-poky-linux';
    final crossBin = p.join(nativeSysroot, 'usr', 'bin', triple);

    final gcc = File(p.join(crossBin, '$triple-gcc'));
    if (!gcc.existsSync()) {
      return CrossResolveResult.failed('cross gcc not found: ${gcc.path}');
    }
    final compilerVersion = await _gccVersion(gcc);
    final egl = File(p.join(sysroot, 'usr', 'include', 'EGL', 'egl.h'));
    if (!egl.existsSync()) {
      return CrossResolveResult.failed(
        'sysroot missing EGL headers (${egl.path}) — is this the '
        '${target.recipe} recipe-sysroot?',
      );
    }

    final cpuFlags = target.cpuFlags.isNotEmpty
        ? target.cpuFlags
        : _defaultCpuFlags;
    final emitDir = workspace.ensurePlatformDir(
      'cross-$triple-${sysrootKey(target)}',
    );
    final cmakeTc = _emitter.emitCMake(
      outDir: emitDir,
      triple: triple,
      crossBin: crossBin,
      sysroot: sysroot,
      cpuFlags: cpuFlags,
    );
    final mesonCross = _emitter.emitMeson(
      outDir: emitDir,
      triple: triple,
      crossBin: crossBin,
      sysroot: sysroot,
      cpuFlags: cpuFlags,
    );

    final profile = CrossProfile(
      providerName: name,
      targetTriple: triple,
      cc: p.join(crossBin, '$triple-gcc'),
      cxx: p.join(crossBin, '$triple-g++'),
      ar: p.join(crossBin, '$triple-ar'),
      strip: p.join(crossBin, '$triple-strip'),
      targetSysroot: sysroot,
      nativeSysroot: nativeSysroot,
      cFlags: cpuFlags,
      cxxFlags: cpuFlags,
      pkgConfig: PkgConfig(
        sysrootDir: sysroot,
        libdir: [
          p.join(sysroot, 'usr', 'lib', 'pkgconfig'),
          p.join(sysroot, 'usr', 'share', 'pkgconfig'),
        ],
      ),
      cmakeToolchainFile: cmakeTc,
      mesonCrossFile: mesonCross,
    );
    final lockEntry = LockedTarget(
      provider: name,
      triple: triple,
      // The located recipe workdir version (e.g. "1.0-r0"). Nothing is fetched
      // here, so there is no artifact to sha; this machine-independent version
      // catches an OE tree rebuilt to a newer recipe.
      toolchainVersion: p.basename(versionDir.path),
      // The native gcc version distinguishes toolchains that share a recipe PV
      // but ship a different compiler (e.g. two Yocto releases) — a stronger
      // pin than the recipe version alone.
      compilerVersion: compilerVersion,
      sysrootKey: sysrootKey(target),
      buildKey: buildKey(target),
    );
    return CrossResolveResult.ok(profile, lockEntry: lockEntry);
  }

  Directory? _newestChild(Directory parent) {
    final dirs =
        parent.listSync(followLinks: false).whereType<Directory>().toList()
          ..sort(
            (a, b) => _compareVersions(p.basename(a.path), p.basename(b.path)),
          );
    return dirs.isEmpty ? null : dirs.last;
  }

  /// Compare two OE version-dir names (e.g. `1.0-r0`, `2.1.0+gitAUTOINC+...`)
  /// numerically, so `10.0` sorts after `9.0` (a plain string compare would
  /// pick `9.0`). Compares the numeric runs component-wise, falling back to a
  /// string compare when those are equal.
  static int _compareVersions(String a, String b) {
    final na = _numericParts(a);
    final nb = _numericParts(b);
    for (var i = 0; i < na.length && i < nb.length; i++) {
      final c = na[i].compareTo(nb[i]);
      if (c != 0) return c;
    }
    final byCount = na.length.compareTo(nb.length);
    return byCount != 0 ? byCount : a.compareTo(b);
  }

  static List<int> _numericParts(String s) => RegExp(
    r'\d+',
  ).allMatches(s).map((m) => int.tryParse(m.group(0)!) ?? 0).toList();

  /// The cross compiler's version via `-dumpfullversion` (falling back to
  /// `-dumpversion`), or null if the probe fails — a version probe must never
  /// fail resolution.
  Future<String?> _gccVersion(File gcc) async {
    for (final flag in const ['-dumpfullversion', '-dumpversion']) {
      try {
        final r = await Process.run(gcc.path, [flag]);
        if (r.exitCode == 0) {
          final out = (r.stdout as String).trim();
          if (out.isNotEmpty) return out;
        }
      } on ProcessException {
        // Not runnable (e.g. a stub) — fall through to null.
      }
    }
    return null;
  }
}
