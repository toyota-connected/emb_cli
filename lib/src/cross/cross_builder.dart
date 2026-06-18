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
  CrossBuilder(
    this.profile, {
    ProcessRunner runProcess = defaultProcessRunner,
    bool neutralizeHostEnv = true,
    bool hostTools = false,
    String? Function(String tool)? resolveHostTool,
  }) : _run = runProcess,
       _neutralize = neutralizeHostEnv,
       _hostTools = hostTools,
       _resolveHostTool = resolveHostTool ?? _hostToolOnPath;

  final CrossProfile profile;
  final ProcessRunner _run;

  /// When true, run the host's build tool (`cmake`/`meson`, resolved from the
  /// host `PATH`) rather than whichever the profile's build env resolves — some
  /// OE SDKs pin an old `nativesdk-cmake`/`-meson` below a project's required
  /// minimum. The OE env + toolchain/cross file are still applied; only the
  /// configure-tool binary changes.
  final bool _hostTools;

  /// Resolves a host build tool (`cmake`/`meson`) to an absolute path, or null
  /// if absent. Injectable so tests don't depend on the runner's real tools.
  final String? Function(String tool) _resolveHostTool;

  /// Whether to blank the host *compiler selection* (`CC`/`CXX`/`CPP`) before
  /// applying the profile env. True for cross builds (the compiler comes from
  /// the toolchain file); false for a native `local` build, which keeps the
  /// host's compiler. Stray host `*FLAGS` are blanked in **both** modes so a
  /// `CXXFLAGS=-stdlib=libc++` from a shell profile can't reach the build.
  final bool _neutralize;

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
    // Stray host flag vars are dropped in both modes.
    for (final v in const ['CFLAGS', 'CXXFLAGS', 'CPPFLAGS', 'LDFLAGS']) v: '',
    // The compiler selection is dropped only for cross (toolchain-file driven).
    if (_neutralize)
      for (final v in const ['CC', 'CXX', 'CPP']) v: '',
    ...profile.buildEnv(),
  };

  /// Default [_resolveHostTool]: the first [tool] on the *host* `PATH`
  /// (`Platform.environment`), or null if none.
  static String? _hostToolOnPath(String tool) {
    final path = Platform.environment['PATH'];
    if (path == null) return null;
    for (final dir in path.split(Platform.isWindows ? ';' : ':')) {
      if (dir.isEmpty) continue;
      final exe = File(p.join(dir, tool));
      if (exe.existsSync()) return exe.path;
    }
    return null;
  }

  Future<CrossBuildResult> _cmake(
    Directory src,
    Directory build,
    Map<String, String> defines,
    List<String> cmakeArgs,
    String buildType,
  ) async {
    final tc = profile.cmakeToolchainFile;
    // Some OE SDKs pin an old nativesdk-cmake on the build env's PATH; host-
    // tools selects the host's newer binary by absolute path (the process exe
    // is resolved via the passed env's PATH, so a bare 'cmake' would still hit
    // the SDK's).
    final String cmakeExe;
    if (_hostTools) {
      final host = _resolveHostTool('cmake');
      if (host == null) {
        return CrossBuildResult(
          success: false,
          buildDir: build.path,
          message: 'host_build_tools set but no cmake found on the host PATH',
        );
      }
      cmakeExe = host;
    } else {
      cmakeExe = 'cmake';
    }
    final configure = await _run(cmakeExe, [
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
    final compile = await _run(cmakeExe, [
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
    // Same rationale as _cmake: bypass an SDK's pinned-old meson when asked.
    final String mesonExe;
    if (_hostTools) {
      final host = _resolveHostTool('meson');
      if (host == null) {
        return CrossBuildResult(
          success: false,
          buildDir: build.path,
          message: 'host_build_tools set but no meson found on the host PATH',
        );
      }
      mesonExe = host;
    } else {
      mesonExe = 'meson';
    }
    final setup = await _run(mesonExe, [
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
