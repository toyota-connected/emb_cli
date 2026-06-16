import 'dart:io';

import 'package:emb_cli/src/cross/cross_profile.dart';
import 'package:emb_cli/src/cross/process_runner.dart';
import 'package:path/path.dart' as p;

/// Outcome of a single cross configure+build.
class CrossBuildResult {
  const CrossBuildResult({
    required this.success,
    required this.buildDir,
    this.backend,
    this.message,
  });

  final bool success;
  final String buildDir;

  /// The backend label, when produced by [CrossBuilder.buildBackends].
  final String? backend;

  /// Failure detail (the failing step's stderr), when [success] is false.
  final String? message;
}

/// Configures and builds a CMake or Meson project under a resolved
/// [CrossProfile] — the consumer of the cross layer.
///
/// The profile supplies the toolchain file (CMake) / cross file (Meson) and the
/// full build environment ([CrossProfile.buildEnv]); per-backend variation is
/// passed as extra `-D` defines. All process invocation goes through the
/// injectable [ProcessRunner] seam, so the command construction is unit-tested
/// without a real cross toolchain.
class CrossBuilder {
  CrossBuilder(this.profile, {ProcessRunner runProcess = defaultProcessRunner})
    : _run = runProcess;

  final CrossProfile profile;
  final ProcessRunner _run;

  /// Configure [sourceDir] into [buildDir] with [generator] + [defines] and the
  /// profile's toolchain/env, then build.
  Future<CrossBuildResult> build({
    required Directory sourceDir,
    required Directory buildDir,
    required CrossGenerator generator,
    Map<String, String> defines = const {},
    List<String> cmakeArgs = const [],
    String buildType = 'Release',
  }) {
    buildDir.createSync(recursive: true);
    return switch (generator) {
      CrossGenerator.cmake => _cmake(
        sourceDir,
        buildDir,
        defines,
        cmakeArgs,
        buildType,
      ),
      CrossGenerator.meson => _meson(sourceDir, buildDir, defines, buildType),
    };
  }

  /// Build [sourceDir] once per backend in [backends] (name → extra defines),
  /// each into `<buildRoot>/build-<name>`. Mirrors the scripts' per-backend
  /// loop (wayland-egl, wayland-vulkan, drm-kms-egl, drm-kms-vulkan, software).
  Future<List<CrossBuildResult>> buildBackends({
    required Directory sourceDir,
    required Directory buildRoot,
    required CrossGenerator generator,
    required Map<String, Map<String, String>> backends,
    List<String> cmakeArgs = const [],
    String buildType = 'Release',
  }) async {
    final out = <CrossBuildResult>[];
    for (final entry in backends.entries) {
      final dir = Directory(p.join(buildRoot.path, 'build-${entry.key}'));
      final r = await build(
        sourceDir: sourceDir,
        buildDir: dir,
        generator: generator,
        defines: entry.value,
        cmakeArgs: cmakeArgs,
        buildType: buildType,
      );
      out.add(
        CrossBuildResult(
          success: r.success,
          buildDir: r.buildDir,
          backend: entry.key,
          message: r.message,
        ),
      );
    }
    return out;
  }

  /// The configure/build environment: the profile's env, but with the host's
  /// compiler variables neutralized first so e.g. a clang
  /// `CXXFLAGS=-stdlib=libc++` from the host shell can't poison a cross `gcc`
  /// build. The profile's own values (a Yocto SDK's `CC`/`CXX`/`CFLAGS`)
  /// override the blanks; an ARM GNU profile leaves them empty (its flags live
  /// in the toolchain file).
  Map<String, String> _env() => {
    for (final v in const [
      'CC',
      'CXX',
      'CPP',
      'CFLAGS',
      'CXXFLAGS',
      'CPPFLAGS',
      'LDFLAGS',
    ])
      v: '',
    ...profile.buildEnv(),
  };

  Future<CrossBuildResult> _cmake(
    Directory src,
    Directory build,
    Map<String, String> defines,
    List<String> cmakeArgs,
    String buildType,
  ) async {
    final tc = profile.cmakeToolchainFile;
    final configure = await _run('cmake', [
      '-S',
      src.path,
      '-B',
      build.path,
      if (tc != null && tc.isNotEmpty) '-DCMAKE_TOOLCHAIN_FILE=$tc',
      '-DCMAKE_BUILD_TYPE=$buildType',
      for (final e in defines.entries) '-D${e.key}=${e.value}',
      ...cmakeArgs,
    ], environment: _env());
    if (configure.exitCode != 0) {
      return CrossBuildResult(
        success: false,
        buildDir: build.path,
        message: 'cmake configure failed: ${configure.stderr}',
      );
    }
    final compile = await _run('cmake', [
      '--build',
      build.path,
      '--parallel',
    ], environment: _env());
    return CrossBuildResult(
      success: compile.exitCode == 0,
      buildDir: build.path,
      message: compile.exitCode == 0
          ? null
          : 'cmake build failed: ${compile.stderr}',
    );
  }

  Future<CrossBuildResult> _meson(
    Directory src,
    Directory build,
    Map<String, String> defines,
    String buildType,
  ) async {
    final cross = profile.mesonCrossFile;
    final setup = await _run('meson', [
      'setup',
      build.path,
      src.path,
      if (cross != null && cross.isNotEmpty) ...['--cross-file', cross],
      '--buildtype',
      buildType.toLowerCase(),
      for (final e in defines.entries) '-D${e.key}=${e.value}',
    ], environment: _env());
    if (setup.exitCode != 0) {
      return CrossBuildResult(
        success: false,
        buildDir: build.path,
        message: 'meson setup failed: ${setup.stderr}',
      );
    }
    final compile = await _run('ninja', [
      '-C',
      build.path,
    ], environment: _env());
    return CrossBuildResult(
      success: compile.exitCode == 0,
      buildDir: build.path,
      message: compile.exitCode == 0 ? null : 'ninja failed: ${compile.stderr}',
    );
  }
}
