import 'package:args/command_runner.dart';
import 'package:emb_cli/src/commands/positional_args.dart';
import 'package:emb_cli/src/engine/engine_artifacts.dart';
import 'package:emb_cli/src/host/host_info.dart';
import 'package:emb_cli/src/workspace/workspace.dart';
import 'package:mason_logger/mason_logger.dart';

/// {@template engine_command}
/// `emb engine` — provision Flutter engine runtime artifacts.
///
/// Default mode is **auto**: download the prebuilt engine SDK for the resolved
/// commit when published, otherwise report that a source build is required
/// (the build path is a later phase). `--mode` restricts to specific runtime
/// modes.
/// {@endtemplate}
class EngineCommand extends Command<int> {
  /// {@macro engine_command}
  EngineCommand({
    required Logger logger,
    HostInfo? host,
    EngineArtifacts Function(Workspace ws)? engineFactory,
  }) : _logger = logger,
       _host = host,
       _engineFactory = engineFactory ?? EngineArtifacts.new {
    argParser
      ..addOption(
        'workspace',
        abbr: 'w',
        help: r'Workspace root (defaults to $FLUTTER_WORKSPACE or cwd).',
      )
      ..addOption(
        'commit',
        help:
            'Engine commit (defaults to '
            '<workspace>/flutter/bin/internal/engine.version).',
      )
      ..addOption(
        'arch',
        help: 'Engine arch token (defaults to the host arch).',
      )
      ..addMultiOption(
        'mode',
        abbr: 'm',
        help:
            'Runtime modes to fetch (others are auto-fetched on demand by '
            '`emb bundle`/`build`).',
        allowed: engineRuntimeModes,
        defaultsTo: const ['release'],
      )
      ..addFlag(
        'clean',
        help: 're-stage bundles even when already present.',
        negatable: false,
      )
      ..addFlag(
        'check',
        help: 'Only check prebuilt availability; do not download.',
        negatable: false,
      );
  }

  final Logger _logger;
  final HostInfo? _host;
  final EngineArtifacts Function(Workspace ws) _engineFactory;

  @override
  String get description =>
      'Fetch prebuilt Flutter engine artifacts (auto fetch-else-build).';

  @override
  String get name => 'engine';

  @override
  Future<int> run() async {
    rejectPositionals(this);
    final args = argResults!;
    final host = _host ?? HostInfo.detect();
    final workspace = Workspace.resolve(override: args['workspace'] as String?);

    final commit = (args['commit'] as String?) ?? workspace.engineCommit();
    if (commit == null || commit.isEmpty) {
      _logger.err(
        'Could not determine the engine commit. '
        'Provide --commit or ensure '
        '${workspace.flutterDir.path}/bin/internal/engine.version exists.',
      );
      return ExitCode.usage.code;
    }
    // Determine the proper engine SDK arch token for this machine (or honor
    // an explicit --arch for cross-fetching a target architecture).
    final arch = EngineArtifacts.engineArch(
      (args['arch'] as String?) ?? host.machineArch,
    );
    final modes = args['mode'] as List<String>;

    _logger.info(
      'Engine commit: $commit  arch: $arch '
      '(host: ${host.machineArch})  modes: ${modes.join(", ")}',
    );

    final engine = _engineFactory(workspace);
    var anyBuildNeeded = false;
    var anyFailed = false;
    try {
      for (final mode in modes) {
        if (args['check'] as bool) {
          final available = await engine.isAvailable(mode, arch, commit);
          _logger.info('  $mode: ${available ? "available" : "NOT published"}');
          if (!available) anyBuildNeeded = true;
          continue;
        }

        final progress = _logger.progress('Engine $mode');
        final result = await engine.fetch(
          runtime: mode,
          arch: arch,
          commit: commit,
          clean: args['clean'] as bool,
        );
        switch (result.status) {
          case EngineFetchStatus.fetched:
            progress.complete('Engine $mode → ${result.bundleDir}');
          case EngineFetchStatus.upToDate:
            progress.complete('Engine $mode already up to date');
          case EngineFetchStatus.unavailable:
            progress.fail('Engine $mode: no prebuilt — source build required');
            anyBuildNeeded = true;
          case EngineFetchStatus.failed:
            progress.fail('Engine $mode: ${result.message}');
            anyFailed = true;
        }
      }
    } finally {
      engine.close();
    }

    if (anyFailed) return ExitCode.software.code;
    if (anyBuildNeeded) {
      _logger
        ..info('')
        ..warn(
          'One or more modes have no published prebuilt. '
          'Source-build (gclient + gn + autoninja) is not yet implemented in '
          'emb — run the legacy flutter_workspace.py engine build, or build '
          'from meta-flutter/flutter-engine, for now.',
        );
      return ExitCode.unavailable.code;
    }
    return ExitCode.success.code;
  }
}
