import 'dart:io';

import 'package:emb_cli/src/cross/build_jobs.dart';
import 'package:emb_cli/src/cross/cross_profile.dart';
import 'package:emb_cli/src/cross/overlay_builder.dart';
import 'package:emb_cli/src/cross/process_runner.dart';
import 'package:emb_cli/src/cross/toolchain_emitter.dart';
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
    List<String> hostToolBins = const [],
    String? Function(String tool)? resolveHostTool,
    String? launcher,
    String? ccacheBaseDir,
    OverlayPaths? overlay,
  }) : _run = runProcess,
       _neutralize = neutralizeHostEnv,
       _hostTools = hostTools,
       _hostToolBins = hostToolBins,
       _resolveHostTool = resolveHostTool ?? _hostToolOnPath,
       _launcher = launcher,
       _ccacheBaseDir = ccacheBaseDir,
       _overlay = overlay;

  final CrossProfile profile;
  final ProcessRunner _run;

  /// Search paths for augment libraries built into a per-workspace overlay
  /// prefix (outside the sysroot). Null when there are no augments. Consumed as
  /// `CMAKE_FIND_ROOT_PATH`/`CMAKE_PREFIX_PATH` (find_package/find_library) plus
  /// a pkg-config env that searches the overlay before the sysroot.
  final OverlayPaths? _overlay;

  /// The overlay only when it is a *separate* prefix from the sysroot. When
  /// augments are staged into the sysroot itself its prefix equals the sysroot,
  /// and there is nothing extra to wire: the sysroot's own CMAKE_SYSROOT +
  /// pkg-config env already find them. Re-adding the sysroot as a find root
  /// would in fact break the build — an aarch64 `sysroot/bin/gmake` then
  /// shadows the host make and CMake tries to run it under qemu.
  OverlayPaths? get _separateOverlay =>
      (_overlay != null && _overlay.prefix != profile.targetSysroot)
      ? _overlay
      : null;

  /// Compiler-cache launcher executable (`ccache`/`sccache`), already resolved
  /// on `PATH`, or null. Applied to CMake as `CMAKE_<LANG>_COMPILER_LAUNCHER`.
  final String? _launcher;

  /// `CCACHE_BASEDIR` for the build env (ccache only) so cache hits survive a
  /// workspace relocation; null to leave it unset.
  final String? _ccacheBaseDir;

  /// When true, run the host's build tool (`cmake`/`meson`, resolved from the
  /// host `PATH`) rather than whichever the profile's build env resolves — some
  /// OE SDKs pin an old `nativesdk-cmake`/`-meson` below a project's required
  /// minimum. The OE env + toolchain/cross file are still applied; only the
  /// configure-tool binary changes.
  final bool _hostTools;

  /// Bin dirs of `host: true` augments to prepend to the build PATH, so the
  /// cross build's `find_program` (which searches the host PATH) resolves a
  /// build-machine tool — e.g. a code generator it runs during the target
  /// build. Empty for builds with no host augments.
  final List<String> _hostToolBins;

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
  Map<String, String> _env() {
    final env = <String, String>{
      // Stray host flag vars are dropped in both modes.
      for (final v in const ['CFLAGS', 'CXXFLAGS', 'CPPFLAGS', 'LDFLAGS'])
        v: '',
      // The compiler selection is dropped only for cross (toolchain-driven).
      if (_neutralize)
        for (final v in const ['CC', 'CXX', 'CPP']) v: '',
      ...profile.buildEnv(),
      // Augment overlay pkg-config: search the overlay's .pc files before the
      // sysroot's (supersedes the profile's PKG_CONFIG_LIBDIR/SYSROOT_DIR).
      if (_separateOverlay case final ov?) ...ov.pkgConfigEnv(profile),
    };
    if (_separateOverlay case final ov?) {
      // The augment lives in a per-workspace overlay prefix *outside* the
      // sysroot, so pkg-config's PKG_CONFIG_SYSROOT_DIR wrongly rebases the
      // overlay's own .pc paths under the sysroot. Add the overlay include/lib
      // dirs as real compiler flags too; cmake appends $CFLAGS/$LDFLAGS to the
      // toolchain-file flags, so the header/lib are found regardless of what
      // pkg-config reports. (These are emb-controlled, not host — safe to set
      // over the neutralized blanks.)
      final inc = ov.includeDirs.map((d) => '-I$d').join(' ');
      final lib = ov.libDirs.map((d) => '-L$d').join(' ');
      String prepend(String extra, String? cur) =>
          [extra, cur ?? ''].where((s) => s.isNotEmpty).join(' ');
      env['CFLAGS'] = prepend(inc, env['CFLAGS']);
      env['CXXFLAGS'] = prepend(inc, env['CXXFLAGS']);
      env['LDFLAGS'] = prepend(lib, env['LDFLAGS']);
    }
    if (_hostToolBins.isNotEmpty) {
      // Prepend host-augment bin dirs so a cross `find_program` resolves the
      // build-machine tool. profile.buildEnv() may not set PATH, in which case
      // the child would inherit the parent's — make that explicit here.
      final cur = env['PATH'] ?? Platform.environment['PATH'] ?? '';
      env['PATH'] = [..._hostToolBins, if (cur.isNotEmpty) cur].join(':');
    }
    // ccache: Meson auto-detects it on PATH; CCACHE_BASEDIR lets hits survive a
    // workspace relocation. Harmless (ignored) for the CMake/sccache paths.
    if (_launcher == 'ccache' && _ccacheBaseDir != null) {
      env['CCACHE_BASEDIR'] = _ccacheBaseDir;
    }
    return env;
  }

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
    final configure = await _run(
      cmakeExe,
      [
        '-S',
        src.path,
        '-B',
        build.path,
        if (tc != null && tc.isNotEmpty) '-DCMAKE_TOOLCHAIN_FILE=$tc',
        '-DCMAKE_BUILD_TYPE=$buildType',
        if (_launcher != null) ...[
          '-DCMAKE_C_COMPILER_LAUNCHER=$_launcher',
          '-DCMAKE_CXX_COMPILER_LAUNCHER=$_launcher',
        ],
        // Augment overlay prefix (outside the sysroot): add it as a find root
        // and prefix so find_package/find_library resolve header/config
        // augments (e.g. Vulkan-Headers). CMAKE_SYSROOT stays a find root too.
        if (_separateOverlay case final ov?) ...[
          '-DCMAKE_FIND_ROOT_PATH=${ov.prefix}',
          '-DCMAKE_PREFIX_PATH=${ov.prefix}',
        ],
        for (final e in defines.entries) '-D${e.key}=${e.value}',
        ...cmakeArgs,
      ],
      environment: _env(),
      output: ProcessOutputMode.stream,
    );
    if (configure.exitCode != 0) {
      return CrossBuildResult(
        success: false,
        buildDir: build.path,
        message: 'cmake configure failed: ${configure.stderr}',
      );
    }
    final compile = await _run(
      cmakeExe,
      ['--build', build.path, '--parallel', '${cmakeBuildJobs()}'],
      environment: _env(),
      output: ProcessOutputMode.stream,
    );
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
    // Some providers (e.g. arm-gnu) supply only a CMake toolchain file, which
    // leaves mesonCrossFile null. Without a cross file meson silently does a
    // *native* build with the host compiler (sysroot -L/-I leak in via cFlags,
    // giving confusing "file in wrong format" link errors), so emit one from
    // the profile. Guarded by _neutralize so the native `local` build stays
    // host-native.
    var cross = profile.mesonCrossFile;
    if ((cross == null || cross.isEmpty) && _neutralize) {
      cross = const ToolchainEmitter().emitMeson(
        outDir: build.parent,
        triple: profile.targetTriple,
        crossBin: p.dirname(profile.cc),
        sysroot: profile.targetSysroot,
        cpuFlags: profile.cFlags,
      );
    }
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
    final setup = await _run(
      mesonExe,
      [
        'setup',
        build.path,
        src.path,
        if (cross != null && cross.isNotEmpty) ...['--cross-file', cross],
        '--buildtype',
        buildType.toLowerCase(),
        for (final e in defines.entries) '-D${e.key}=${e.value}',
      ],
      environment: _env(),
      output: ProcessOutputMode.stream,
    );
    if (setup.exitCode != 0) {
      return CrossBuildResult(
        success: false,
        buildDir: build.path,
        message: 'meson setup failed: ${setup.stderr}',
      );
    }
    final compile = await _run(
      'ninja',
      ['-C', build.path],
      environment: _env(),
      output: ProcessOutputMode.stream,
    );
    return CrossBuildResult(
      success: compile.exitCode == 0,
      buildDir: build.path,
      message: compile.exitCode == 0 ? null : 'ninja failed: ${compile.stderr}',
    );
  }
}
