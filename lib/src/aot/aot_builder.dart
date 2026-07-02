import 'dart:io';

import 'package:emb_cli/src/cross/process_runner.dart';
import 'package:emb_cli/src/engine/engine_artifacts.dart';
import 'package:emb_cli/src/flutter/flutter_sdk.dart';
import 'package:emb_cli/src/host/host_info.dart';
import 'package:emb_cli/src/workspace/workspace.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

/// Per-runtime-mode AOT build outcome.
class AotModeResult {
  const AotModeResult({
    required this.mode,
    required this.success,
    this.output,
    this.message,
  });

  final String mode;
  final bool success;

  /// Path to the produced `libapp.so.<mode>`, when successful.
  final String? output;
  final String? message;
}

/// Aggregate AOT build result.
class AotResult {
  const AotResult(this.modes);
  final List<AotModeResult> modes;
  bool get success => modes.isNotEmpty && modes.every((m) => m.success);
}

/// Builds release/profile AOT app images for a Flutter app.
///
/// Ports `create_aot.py`'s `create_platform_aot`: for each runtime mode,
/// `flutter build bundle`, then a `frontend_server` kernel snapshot, then
/// `gen_snapshot --snapshot_kind=app-aot-elf` to produce `libapp.so.<mode>`.
/// Takes the engine-artifact-resolution idea from `flutterpi_tool` (locate the
/// toolchain in the workspace rather than relying on a hand-set env), while
/// keeping `create_aot.py`'s explicit snapshot invocation.
class AotBuilder {
  AotBuilder(
    this.workspace, {
    HostInfo? host,
    this.runProcess = defaultProcessRunner,
    this.glibcSysroot,
  }) : host = host ?? HostInfo.detect();

  final Workspace workspace;
  final HostInfo host;

  /// Optional override directory holding `ld-linux-*.so` + libc to run
  /// gen_snapshot under. When null, the gen_snapshot's own bundled `../lib64`
  /// is used (engine artifacts ship `clang_x64/lib64`), so the prebuilt runs
  /// regardless of the host's glibc.
  final String? glibcSysroot;

  /// The shared process seam. AOT's flutter/gen_snapshot/kernel-snapshot steps
  /// pass `ProcessOutputMode.inherit`, wiring child stdio to the parent TTY
  /// (as before). Injectable for tests.
  final ProcessRunner runProcess;

  String get _flutterBin => FlutterSdk(workspace).flutterBin;
  Directory get _hostEngine => Directory(
    p.join(
      workspace.flutterDir.path,
      'bin',
      'cache',
      'artifacts',
      'engine',
      '${host.os.configToken}-${host.flutterArch}',
    ),
  );
  Directory get _engineCommon => Directory(
    p.join(
      workspace.flutterDir.path,
      'bin',
      'cache',
      'artifacts',
      'engine',
      'common',
    ),
  );
  String get _dartSdkBin =>
      p.join(workspace.flutterDir.path, 'bin', 'cache', 'dart-sdk', 'bin');

  /// Host-arch AOT `frontend_server` snapshot shipped with the Dart SDK.
  ///
  /// The engine-artifacts copy (`artifacts/engine/<host>/`) is built on x64 CI
  /// and is x86-64 even inside the `linux-arm64` bundle, so it can't run under
  /// the arm64 `dartaotruntime`. The `dart-sdk/bin/snapshots/` copy is always
  /// host-arch — this is the one modern Flutter itself uses.
  String get _frontendServerAot =>
      p.join(_dartSdkBin, 'snapshots', 'frontend_server_aot.dart.snapshot');

  /// Run `flutter build bundle --<mode>` to produce `build/flutter_assets`.
  ///
  /// For **debug** (JIT) this is the whole "build" — the assets include
  /// `kernel_blob.bin` and there is no AOT/`libapp.so`. profile/release go
  /// through [build] instead (which adds the gen_snapshot step).
  Future<bool> buildAssets({
    required String appPath,
    required String mode,
  }) async {
    final flag = switch (mode) {
      'debug' => '--debug',
      'profile' => '--profile',
      _ => '--release',
    };
    final r = await runProcess(
      _flutterBin,
      ['build', 'bundle', flag],
      workingDirectory: p.absolute(appPath),
      output: ProcessOutputMode.inherit,
    );
    return r.exitCode == 0;
  }

  /// Build AOT images for [modes] (default release + profile) of the app at
  /// [appPath]. [arch] selects the target engine artifact for the cross
  /// gen_snapshot (defaults to host); [genSnapshot] overrides the resolved one.
  Future<AotResult> build({
    required String appPath,
    List<String> modes = const ['release', 'profile'],
    String? arch,
    String? genSnapshot,
    void Function(String step)? onStep,
  }) async {
    final app = p.absolute(appPath);
    final appName = _pubspecName(app);
    if (appName == null) {
      return const AotResult([
        AotModeResult(
          mode: '*',
          success: false,
          message: 'Could not read package name from pubspec.yaml',
        ),
      ]);
    }

    final newScheme = File(_frontendServerAot).existsSync();
    final targetArch = arch ?? host.machineArch;
    final gen = genSnapshot ?? await _resolveGenSnapshot(targetArch, modes);

    final results = <AotModeResult>[];
    for (final mode in modes) {
      onStep?.call('[$mode] flutter build bundle');
      final bundle = await runProcess(
        _flutterBin,
        ['build', 'bundle'],
        workingDirectory: app,
        output: ProcessOutputMode.inherit,
      );
      if (bundle.exitCode != 0) {
        results.add(
          AotModeResult(
            mode: mode,
            success: false,
            message: 'flutter build bundle failed',
          ),
        );
        continue;
      }

      final buildDir = _firstBuildDir(app);
      if (buildDir == null) {
        results.add(
          AotModeResult(
            mode: mode,
            success: false,
            message: 'No .dart_tool/flutter_build/<hash> dir found',
          ),
        );
        continue;
      }

      onStep?.call('[$mode] kernel snapshot');
      final kernelOk = await _kernelSnapshot(
        app: app,
        appName: appName,
        mode: mode,
        buildDir: buildDir,
        newScheme: newScheme,
      );
      if (kernelOk != 0) {
        results.add(
          AotModeResult(
            mode: mode,
            success: false,
            message: 'kernel snapshot failed',
          ),
        );
        continue;
      }

      onStep?.call('[$mode] gen_snapshot app-aot-elf');
      if (gen == null) {
        final token = EngineArtifacts.engineArch(targetArch);
        results.add(
          AotModeResult(
            mode: mode,
            success: false,
            message:
                'No $token gen_snapshot for engine '
                '${workspace.engineCommit() ?? "<unknown>"} — run '
                '`emb engine --arch $targetArch` (its gen_snapshot must come '
                'from the same engine as the SDK frontend_server)',
          ),
        );
        continue;
      }
      final out = 'libapp.so.$mode';
      final (genExe, genLead) = _genSnapshotInvocation(gen);
      final genResult = await runProcess(
        genExe,
        [
          ...genLead,
          '--deterministic',
          '--snapshot_kind=app-aot-elf',
          '--elf=$out',
          '--strip',
          '--obfuscate',
          p.join(buildDir, 'app.dill'),
        ],
        workingDirectory: app,
        output: ProcessOutputMode.inherit,
      );
      final genCode = genResult.exitCode;
      results.add(
        AotModeResult(
          mode: mode,
          success: genCode == 0,
          output: genCode == 0 ? p.join(app, out) : null,
          message: genCode == 0 ? null : 'gen_snapshot failed',
        ),
      );
    }
    return AotResult(results);
  }

  Future<int> _kernelSnapshot({
    required String app,
    required String appName,
    required String mode,
    required String buildDir,
    required bool newScheme,
  }) async {
    final dartRuntime = newScheme
        ? p.join(_dartSdkBin, 'dartaotruntime')
        : p.join(_dartSdkBin, 'dart');
    final frontend = newScheme
        ? _frontendServerAot
        : p.join(_hostEngine.path, 'frontend_server.dart.snapshot');
    final depfile = p.join(
      buildDir,
      newScheme ? 'kernel_snapshot_program.d' : 'kernel_snapshot.d',
    );

    final isRelease = mode == 'release';
    var patched = p.join(
      _engineCommon.path,
      isRelease ? 'flutter_patched_sdk_product' : 'flutter_patched_sdk',
    );
    if (!Directory(patched).existsSync()) {
      patched = p.join(_engineCommon.path, 'flutter_patched_sdk');
    }

    final args = <String>[
      '--disable-dart-dev',
      frontend,
      '--sdk-root',
      '$patched/',
      '--target=flutter',
      '--no-print-incremental-dependencies',
      '-Ddart.vm.profile=${mode == "profile"}',
      '-Ddart.vm.product=$isRelease',
      '--delete-tostring-package-uri=dart:ui',
      '--delete-tostring-package-uri=package:flutter',
      if (mode == 'profile') '--track-widget-creation',
      '--aot',
      '--tfa',
      '--target-os',
      'linux',
      '--packages',
      p.join(app, '.dart_tool', 'package_config.json'),
      '--output-dill',
      p.join(buildDir, 'app.dill'),
      '--depfile',
      depfile,
      ..._sourceFlags(app),
      ..._nativeAssets(buildDir),
      '--verbosity=error',
      'package:$appName/main.dart',
    ];
    final r = await runProcess(
      dartRuntime,
      args,
      workingDirectory: app,
      output: ProcessOutputMode.inherit,
    );
    return r.exitCode;
  }

  /// Optional dart_plugin_registrant source flags (mirrors create_aot.py).
  List<String> _sourceFlags(String app) {
    final reg = File(
      p.join(app, '.dart_tool', 'flutter_build', 'dart_plugin_registrant.dart'),
    );
    if (!reg.existsSync()) return const [];
    return [
      '--source',
      'file://${reg.path}',
      '--source',
      'package:flutter/src/dart_plugin_registrant.dart',
      '-Dflutter.dart_plugin_registrant=file://${reg.path}',
    ];
  }

  /// Optional native_assets.yaml flag (mirrors create_aot.py).
  List<String> _nativeAssets(String buildDir) {
    final f = File(p.join(buildDir, 'native_assets.yaml'));
    return f.existsSync() ? ['--native-assets', f.path] : const [];
  }

  /// Resolve the gen_snapshot for [arch] from the engine-sdk artifact.
  ///
  /// The host is x86_64 (engine artifacts are built on x86_64 CI). Selection is
  /// deterministic by host-vs-target:
  ///  * **cross** (target ≠ host) → the host simulator
  ///    `…/engine-sdk/clang_x64/bin/gen_snapshot` (e.g. `linux_simarm64`),
  ///    which runs on the x86_64 host and emits target code;
  ///  * **native** (target == host) → `…/engine-sdk/bin/gen_snapshot`, or the
  ///    host Flutter SDK's cached gen_snapshot.
  ///
  /// No implicit `$GEN_SNAPSHOT` (it caused stale/arch-mismatched picks); use
  /// the explicit `--gen-snapshot` override for that.
  Future<String?> _resolveGenSnapshot(String arch, List<String> modes) async {
    final targetToken = EngineArtifacts.engineArch(arch);
    final hostToken = EngineArtifacts.engineArch(host.machineArch);
    final cross = targetToken != hostToken;

    final commit = workspace.engineCommit();
    if (commit != null) {
      for (final mode in [...modes, 'release', 'profile', 'debug']) {
        final dir = Directory(
          p.join(
            workspace.platformDir('flutter-engine').path,
            commit,
            'engine-sdk-$mode-$targetToken',
          ),
        );
        if (!dir.existsSync()) continue;
        for (final e in dir.listSync(recursive: true, followLinks: false)) {
          if (e is! File || p.basename(e.path) != 'gen_snapshot') continue;
          // cross → the clang_<host> simulator; native → the plain bin/ build.
          if (cross == e.path.contains('${p.separator}clang_')) return e.path;
        }
      }
    }

    if (!cross) {
      final hostGen = p.join(_hostEngine.path, 'gen_snapshot');
      if (File(hostGen).existsSync()) return hostGen;
    }
    return null;
  }

  /// Build the (executable, leading-args) to run [gen] under a compatible
  /// loader. Prefers [glibcSysroot]; otherwise the gen_snapshot's own bundled
  /// `../lib64` (engine artifacts ship `clang_x64/lib64` with `ld-linux` +
  /// libc), so a prebuilt built against a newer glibc still runs on an older
  /// host. Falls back to a direct call when no bundled loader exists (e.g. the
  /// host SDK gen_snapshot, which uses the host's own glibc).
  (String, List<String>) _genSnapshotInvocation(String gen) {
    final libDir = glibcSysroot ?? _bundledLibDir(gen);
    if (libDir == null) return (gen, const []);
    final loader = File(p.join(libDir, 'ld-linux-x86-64.so.2'));
    if (!loader.existsSync()) return (gen, const []);
    return (loader.path, ['--library-path', libDir, gen]);
  }

  /// The `lib64` sibling of [gen]'s `bin/` dir, if it exists
  /// (`<…>/clang_x64/bin/gen_snapshot` → `<…>/clang_x64/lib64`).
  String? _bundledLibDir(String gen) {
    final lib = p.join(p.dirname(p.dirname(gen)), 'lib64');
    return Directory(lib).existsSync() ? lib : null;
  }

  String? _firstBuildDir(String app) {
    final dir = Directory(p.join(app, '.dart_tool', 'flutter_build'));
    if (!dir.existsSync()) return null;
    final hashed = dir.listSync().whereType<Directory>().toList();
    return hashed.isEmpty ? null : hashed.first.path;
  }

  String? _pubspecName(String app) {
    final f = File(p.join(app, 'pubspec.yaml'));
    if (!f.existsSync()) return null;
    final doc = loadYaml(f.readAsStringSync());
    if (doc is YamlMap && doc['name'] is String) return doc['name'] as String;
    return null;
  }
}
