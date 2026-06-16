import 'dart:io';

import 'package:emb_cli/src/cross/cross_profile.dart';
import 'package:emb_cli/src/cross/cross_provider.dart';
import 'package:emb_cli/src/cross/cross_target.dart';
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
    final emitDir = workspace.ensurePlatformDir('cross-$triple');
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
    return CrossResolveResult.ok(profile);
  }

  Directory? _newestChild(Directory parent) {
    final dirs =
        parent.listSync(followLinks: false).whereType<Directory>().toList()
          ..sort((a, b) => p.basename(a.path).compareTo(p.basename(b.path)));
    return dirs.isEmpty ? null : dirs.last;
  }
}
