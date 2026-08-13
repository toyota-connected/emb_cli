import 'dart:io';

import 'package:emb_cli/src/cache/store.dart';
import 'package:emb_cli/src/cross/offline_enforcement.dart' show netnsWrap;
import 'package:emb_cli/src/engine/engine_toolchain.dart';

/// Outcome of an engine source build.
enum EngineBuildStatus {
  /// Built from source and adopted into the store.
  built,

  /// Already present in the shared store (a prior build/fetch).
  cached,

  /// This profile/host is not yet wired (a later milestone).
  unsupported,

  /// The build ran but failed.
  failed,
}

/// The result of [EngineBuilder.build].
class EngineBuildResult {
  const EngineBuildResult(this.status, {this.storeRoot, this.message});

  final EngineBuildStatus status;
  final Directory? storeRoot;
  final String? message;
}

/// A single-mode engine build, injectable into `EngineCommand` for testing the
/// fetch-else-build dispatch without a real engine build.
typedef EngineBuildFn =
    Future<EngineBuildResult> Function({
      required String commit,
      required String arch,
      required String mode,
      ToolchainProfile profile,
      bool offline,
      bool strict,
    });

/// A subprocess runner for the build driver, injectable for tests.
typedef EngineProcessRunner =
    Future<ProcessResult> Function(
      String exe,
      List<String> args, {
      String? workingDirectory,
      Map<String, String>? environment,
    });

/// Resolves a target sysroot directory (e.g. an Alpine apk musl sysroot),
/// injected so the build phase can pass `EMB_SYSROOT_DIR` to the recipe.
typedef SysrootResolver = Future<Directory> Function({required String arch});

/// Builds a Flutter engine SDK from source when no prebuilt is published, then
/// adopts the result into the shared store so it is a drop-in for a fetched
/// artifact (same `kind:'engine'` key).
///
/// The heavy orchestration (gclient sync + hooks → gn → ninja → prepare-sdk) is
/// delegated to a shared `build-engine.sh` (design decision D1) driven by
/// [_run]; this class owns the emb-side seam: profile → store key → build →
/// adopt. The offline acquire/build split and the container boundary
/// wrap this in later milestones.
class EngineBuilder {
  EngineBuilder({
    required Store store,
    required File buildScript,
    EngineProcessRunner? runProcess,
    SysrootResolver? alpineSysroot,
  }) : _store = store,
       _script = buildScript,
       _run = runProcess ?? _defaultRunner,
       _alpineSysroot = alpineSysroot;

  final Store _store;
  final File _script;
  final EngineProcessRunner _run;
  final SysrootResolver? _alpineSysroot;

  static const String kind = 'engine';

  /// Store kind for the fetched, self-contained engine source closure.
  static const String srcKind = 'engine-src';

  static Future<ProcessResult> _defaultRunner(
    String exe,
    List<String> args, {
    String? workingDirectory,
    Map<String, String>? environment,
  }) => Process.run(
    exe,
    args,
    workingDirectory: workingDirectory,
    environment: environment,
  );

  /// Build (or reuse a cached) engine SDK for [commit]/[arch]/[mode] under
  /// [profile]. An [offline] build requires the fetch phase to have populated
  /// the closure first.
  Future<EngineBuildResult> build({
    required String commit,
    required String arch,
    required String mode,
    ToolchainProfile profile = ToolchainProfile.linuxGlibc,
    Directory? outDir,
    bool offline = false,
    bool strict = false,
  }) async {
    // Milestone 1 wires only the native linux target; other target-OSes land
    // with their pipelines (doc).
    if (profile.os != TargetOs.linux) {
      return const EngineBuildResult(
        EngineBuildStatus.unsupported,
        message: 'only linux targets are wired in this milestone',
      );
    }

    final wantOffline = offline || strict;
    final key = profile.storeKey(commit: commit, arch: arch, mode: mode);

    // Cache hit → the drop-in is already in the shared store.
    final cachedRoot = _store.rootOf(kind, key);
    if (cachedRoot.existsSync()) {
      return EngineBuildResult(EngineBuildStatus.cached, storeRoot: cachedRoot);
    }

    // An offline build must build from a previously fetched closure.
    final closure = _store.rootOf(srcKind, commit);
    if (wantOffline && !closure.existsSync()) {
      return EngineBuildResult(
        EngineBuildStatus.unsupported,
        message:
            'offline build needs the fetch phase first: no engine-src closure '
            'for $commit (run `emb engine fetch`)',
      );
    }

    // --offline-strict refuses when real isolation is unavailable, rather than
    // degrading to input-level denial.
    if (strict && !await _netnsAvailable()) {
      return const EngineBuildResult(
        EngineBuildStatus.unsupported,
        message:
            'offline-strict needs a rootless network namespace '
            '(unshare --net --map-root-user), which this host does not '
            'provide; enable unprivileged user namespaces or drop '
            '--offline-strict',
      );
    }

    final missingScript = _requireScript();
    if (missingScript != null) return missingScript;

    // For an Alpine musl target, materialize the apk sysroot and pass it to the
    // recipe via EMB_SYSROOT_DIR (poky-musl uses OE staging instead).
    String? sysrootDir;
    if (profile.libc == Libc.musl &&
        profile.sysrootId == 'alpine' &&
        _alpineSysroot != null) {
      sysrootDir = (await _alpineSysroot(arch: arch)).path;
    }

    // Drive the shared recipe (build phase). It emits `engine-sdk/` under out.
    // Under strict, the whole build tree runs inside one network namespace.
    final built =
        outDir ?? Directory.systemTemp.createTempSync('emb-engine-build-');
    final baseArgv = [
      '/bin/sh',
      _script.path,
      'build',
      mode,
      arch,
      commit,
      profile.libc.token,
      built.path,
    ];
    final argv = strict ? netnsWrap(baseArgv) : baseArgv;
    final result = await _run(
      argv.first,
      argv.sublist(1),
      environment: {
        if (wantOffline) 'EMB_OFFLINE': '1',
        if (closure.existsSync()) 'EMB_SRC_DIR': closure.path,
        if (profile.sysrootId != null) 'EMB_SYSROOT_ID': profile.sysrootId!,
        if (sysrootDir != null) 'EMB_SYSROOT_DIR': sysrootDir,
      },
    );
    if (result.exitCode != 0) {
      return EngineBuildResult(
        EngineBuildStatus.failed,
        message: 'build-engine.sh (build) exited ${result.exitCode}',
      );
    }

    // Adopt the built tree under the same key a fetch would use, making it
    // indistinguishable from a prebuilt (shareable via cache push/export).
    final root = await _store.adopt(kind: kind, key: key, existingDir: built);
    return EngineBuildResult(EngineBuildStatus.built, storeRoot: root);
  }

  /// Fetch phase: run `gclient sync` WITH hooks online and adopt the
  /// self-contained closure into the store as `engine-src/<commit>`, so a later
  /// [build] with `offline: true` needs no network.
  Future<EngineBuildResult> fetch({
    required String commit,
    required String arch,
    required String mode,
    ToolchainProfile profile = ToolchainProfile.linuxGlibc,
  }) async {
    if (profile.os != TargetOs.linux) {
      return const EngineBuildResult(
        EngineBuildStatus.unsupported,
        message: 'only linux targets are wired in this milestone',
      );
    }
    final cached = _store.rootOf(srcKind, commit);
    if (cached.existsSync()) {
      return EngineBuildResult(EngineBuildStatus.cached, storeRoot: cached);
    }
    final missingScript = _requireScript();
    if (missingScript != null) return missingScript;

    final out = Directory.systemTemp.createTempSync('emb-engine-src-');
    final result = await _run('/bin/sh', [
      _script.path,
      'fetch',
      mode,
      arch,
      commit,
      profile.libc.token,
      out.path,
    ]);
    if (result.exitCode != 0) {
      return EngineBuildResult(
        EngineBuildStatus.failed,
        message: 'build-engine.sh (fetch) exited ${result.exitCode}',
      );
    }
    final root = await _store.adopt(
      kind: srcKind,
      key: commit,
      existingDir: out,
    );
    return EngineBuildResult(EngineBuildStatus.built, storeRoot: root);
  }

  /// Whether the host can create a rootless network namespace (the
  /// `--offline-strict` sandbox). Mirrors the cross path's `netnsAvailable`.
  Future<bool> _netnsAvailable() async {
    try {
      final r = await _run('unshare', ['--net', '--map-root-user', 'true']);
      return r.exitCode == 0;
    } on ProcessException {
      return false; // unshare absent (non-Linux) or userns disabled
    }
  }

  EngineBuildResult? _requireScript() {
    if (_script.existsSync()) return null;
    return EngineBuildResult(
      EngineBuildStatus.unsupported,
      message:
          'engine build recipe not found at ${_script.path}; set '
          'EMB_ENGINE_BUILD_SCRIPT to build-engine.sh (design decision D1)',
    );
  }
}
