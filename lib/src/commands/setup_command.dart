import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:emb_cli/src/deps/dependency_resolver.dart';
import 'package:emb_cli/src/engine/engine_artifacts.dart';
import 'package:emb_cli/src/env/env_script.dart';
import 'package:emb_cli/src/flutter/flutter_sdk.dart';
import 'package:emb_cli/src/host/host_info.dart';
import 'package:emb_cli/src/manifest/emb_manifest.dart';
import 'package:emb_cli/src/manifest/manifest_loader.dart';
import 'package:emb_cli/src/pkg/host_provisioner.dart';
import 'package:emb_cli/src/repo/git_repo.dart';
import 'package:emb_cli/src/repo/repo_syncer.dart';
import 'package:emb_cli/src/workspace/workspace.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:path/path.dart' as p;

/// {@template setup_command}
/// `emb setup` — provision a workspace end to end: host dependencies, source
/// repositories, the Flutter SDK, and engine artifacts. Each phase can be
/// skipped. The per-app `aot`/`bundle` steps are run separately.
/// {@endtemplate}
class SetupCommand extends Command<int> {
  /// {@macro setup_command}
  SetupCommand({
    required Logger logger,
    HostInfo? host,
    ManifestLoader loader = const ManifestLoader(),
    HostProvisioner Function(HostInfo host)? provisionerFactory,
    FlutterSdk Function(Workspace ws, HostInfo host)? sdkFactory,
    EngineArtifacts Function(Workspace ws)? engineFactory,
  })  : _logger = logger,
        _host = host,
        _loader = loader,
        _provisionerFactory = provisionerFactory ?? HostProvisioner.forHost,
        _sdkFactory =
            sdkFactory ?? ((ws, host) => FlutterSdk(ws, host: host)),
        _engineFactory = engineFactory ?? EngineArtifacts.new {
    argParser
      ..addMultiOption('config',
          abbr: 'c',
          help: 'Legacy JSON config directory.',
          defaultsTo: const ['configs'])
      ..addMultiOption('packages',
          abbr: 'p', help: 'Directory to discover self-describing manifests.')
      ..addOption('workspace',
          abbr: 'w',
          help: r'Workspace root (defaults to $FLUTTER_WORKSPACE or cwd).')
      ..addOption('flutter-version',
          help: "Flutter version (defaults to globals.json's flutter_version).")
      ..addOption('arch', help: 'Engine arch (defaults to host).')
      ..addMultiOption('mode',
          abbr: 'm',
          help: 'Engine runtime modes to prefetch.',
          allowed: engineRuntimeModes,
          defaultsTo: const ['release'])
      ..addFlag('yes',
          abbr: 'y', help: 'Skip the deps confirmation.', negatable: false)
      ..addFlag('skip-deps', help: 'Skip host dependency install.',
          negatable: false)
      ..addFlag('skip-sync', help: 'Skip repository sync.', negatable: false)
      ..addFlag('skip-flutter', help: 'Skip Flutter SDK install.',
          negatable: false)
      ..addFlag('skip-engine', help: 'Skip engine artifact fetch.',
          negatable: false);
  }

  final Logger _logger;
  final HostInfo? _host;
  final ManifestLoader _loader;
  final HostProvisioner Function(HostInfo host) _provisionerFactory;
  final FlutterSdk Function(Workspace ws, HostInfo host) _sdkFactory;
  final EngineArtifacts Function(Workspace ws) _engineFactory;

  @override
  String get description =>
      'Provision a workspace: deps, repos, Flutter SDK, and engine.';

  @override
  String get name => 'setup';

  @override
  Future<int> run() async {
    final args = argResults!;
    final host = _host ?? HostInfo.detect();
    final workspace = Workspace.resolve(override: args['workspace'] as String?);
    final configDirs = args['config'] as List<String>;

    final manifests = <EmbManifest>[];
    for (final dir in configDirs) {
      manifests.addAll(_loader.loadConfigDir(Directory(dir)));
    }
    for (final dir in args['packages'] as List<String>) {
      manifests.addAll(_loader.discoverPackages(Directory(dir)));
    }

    _logger.info(styleBold.wrap('emb setup → ${workspace.root.path} '
        '(${host.os.name}/${host.machineArch})'));
    workspace.ensureAppDir();

    if (!(args['skip-deps'] as bool)) {
      final code = await _deps(host, manifests, yes: args['yes'] as bool);
      if (code != ExitCode.success.code) return code;
    }
    if (!(args['skip-sync'] as bool)) {
      final code = await _sync(workspace, manifests);
      if (code != ExitCode.success.code) return code;
    }
    if (!(args['skip-flutter'] as bool)) {
      final code = await _flutter(
        workspace,
        host,
        version: args['flutter-version'] as String?,
        configDirs: configDirs,
      );
      if (code != ExitCode.success.code) return code;
    }
    if (!(args['skip-engine'] as bool)) {
      final code = await _engine(
        workspace,
        host,
        arch: args['arch'] as String?,
        modes: args['mode'] as List<String>,
      );
      if (code != ExitCode.success.code) return code;
    }

    // Emit setup_env.sh so the workspace's Flutter/Dart are on PATH.
    final envFile = File(p.join(workspace.root.path, 'setup_env.sh'))
      ..writeAsStringSync(generateSetupEnv(
        workspace: workspace,
        host: host,
        engineVersion: workspace.engineCommit(),
      ));

    _logger
      ..info(lightGreen.wrap('emb setup complete.'))
      ..info('Source the env: . ${p.relative(envFile.path)}');
    return ExitCode.success.code;
  }

  Future<int> _deps(
    HostInfo host,
    List<EmbManifest> manifests, {
    required bool yes,
  }) async {
    _logger.info(styleBold.wrap('▸ Dependencies'));
    final coalesced = DependencyResolver(host).coalesce(manifests);
    if (coalesced.isEmpty) {
      _logger.info('  No applicable host dependencies.');
      return ExitCode.success.code;
    }
    final provisioner = _provisionerFactory(host);
    try {
      if (!await provisioner.isAvailable()) {
        _logger.err('  Package backend "${provisioner.name}" unavailable.');
        return ExitCode.unavailable.code;
      }
      final missing = await provisioner.missing(coalesced.packages.toSet());
      if (missing.isEmpty) {
        _logger.info('  All ${coalesced.packages.length} deps satisfied.');
        return ExitCode.success.code;
      }
      _logger.info('  Missing (${missing.length}): ${missing.join(", ")}');
      if (!yes &&
          !_logger.confirm('  Install ${missing.length} package(s)?',
              defaultValue: true)) {
        _logger.info('  Skipped.');
        return ExitCode.success.code;
      }
      final progress = _logger.progress('  Installing ${missing.length}');
      final result = await provisioner.install(missing);
      if (result.success) {
        progress.complete('  Installed ${result.installed.length} package(s)');
        return ExitCode.success.code;
      }
      progress.fail('  Install failed');
      if (result.message != null) _logger.err(result.message);
      return ExitCode.software.code;
    } finally {
      await provisioner.dispose();
    }
  }

  Future<int> _sync(Workspace workspace, List<EmbManifest> manifests) async {
    _logger.info(styleBold.wrap('▸ Repositories'));
    final seen = <String>{};
    final repos = manifests
        .expand((m) => m.src)
        .map(GitRepo.fromSource)
        .where((r) => seen.add(r.folderName))
        .toList();
    if (repos.isEmpty) {
      _logger.info('  No source repositories.');
      return ExitCode.success.code;
    }
    final progress = _logger.progress('  Syncing ${repos.length} repo(s)');
    var done = 0;
    final results = await const RepoSyncer().syncAll(
      repos,
      workspace.appDir,
      onResult: (r) => progress.update('  [${++done}/${repos.length}] '
          '${r.folderName}${r.success ? "" : " FAILED"}'),
    );
    final failed = results.where((r) => !r.success).toList();
    if (failed.isEmpty) {
      progress.complete('  Synced ${results.length} repo(s)');
      return ExitCode.success.code;
    }
    progress.fail('  ${failed.length} repo(s) failed');
    for (final f in failed) {
      _logger.err('    ${f.folderName}: ${f.message}');
    }
    return ExitCode.software.code;
  }

  Future<int> _flutter(
    Workspace workspace,
    HostInfo host, {
    required String? version,
    required List<String> configDirs,
  }) async {
    _logger.info(styleBold.wrap('▸ Flutter SDK'));
    final resolved = version ?? _versionFromGlobals(configDirs);
    if (resolved == null || resolved.isEmpty) {
      _logger.err('  No Flutter version: set --flutter-version or '
          'globals.json.');
      return ExitCode.usage.code;
    }
    final progress = _logger.progress('  Installing Flutter SDK $resolved');
    final result = await _sdkFactory(workspace, host).install(resolved);
    if (!result.success) {
      progress.fail('  Flutter SDK install failed');
      if (result.message != null) _logger.err(result.message);
      return ExitCode.software.code;
    }
    final commit = result.engineCommit;
    progress.complete('  Flutter SDK $resolved'
        '${commit != null ? " (engine $commit)" : ""}');
    return ExitCode.success.code;
  }

  Future<int> _engine(
    Workspace workspace,
    HostInfo host, {
    required String? arch,
    required List<String> modes,
  }) async {
    _logger.info(styleBold.wrap('▸ Engine artifacts'));
    final commit = workspace.engineCommit();
    if (commit == null) {
      _logger.warn('  No engine.version — skipping (install the SDK first).');
      return ExitCode.success.code;
    }
    final token = EngineArtifacts.engineArch(arch ?? host.machineArch);
    final engine = _engineFactory(workspace);
    var failed = false;
    try {
      for (final mode in modes) {
        final progress = _logger.progress('  Engine $mode');
        final r =
            await engine.fetch(runtime: mode, arch: token, commit: commit);
        switch (r.status) {
          case EngineFetchStatus.fetched:
          case EngineFetchStatus.upToDate:
            progress.complete('  Engine $mode → ${r.bundleDir}');
          case EngineFetchStatus.unavailable:
            progress.fail('  Engine $mode: no prebuilt (source build needed)');
          case EngineFetchStatus.failed:
            progress.fail('  Engine $mode: ${r.message}');
            failed = true;
        }
      }
    } finally {
      engine.close();
    }
    return failed ? ExitCode.software.code : ExitCode.success.code;
  }

  String? _versionFromGlobals(List<String> configDirs) {
    for (final dir in configDirs) {
      final f = File(p.join(dir, 'globals.json'));
      if (!f.existsSync()) continue;
      try {
        final decoded = jsonDecode(f.readAsStringSync());
        if (decoded is Map && decoded['flutter_version'] is String) {
          final v = decoded['flutter_version'] as String;
          if (v.isNotEmpty) return v;
        }
      } on FormatException {
        // skip malformed globals.json
      }
    }
    return null;
  }
}
