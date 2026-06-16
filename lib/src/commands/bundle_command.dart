import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:emb_cli/src/aot/aot_builder.dart';
import 'package:emb_cli/src/bundle/bundle_builder.dart';
import 'package:emb_cli/src/bundle/bundle_pipeline.dart';
import 'package:emb_cli/src/engine/engine_artifacts.dart';
import 'package:emb_cli/src/host/host_info.dart';
import 'package:emb_cli/src/workspace/workspace.dart';
import 'package:mason_logger/mason_logger.dart';

/// {@template bundle_command}
/// `emb bundle` — assemble an ivi-homescreen bundle folder (flutter_assets +
/// icudtl.dat + libapp.so + libflutter_engine.so) from the app build and the
/// staged engine artifacts, in one shot.
/// {@endtemplate}
class BundleCommand extends Command<int> {
  /// {@macro bundle_command}
  BundleCommand({
    required Logger logger,
    HostInfo? host,
    BundleBuilder Function(Workspace ws)? bundleFactory,
    AotBuilder Function(Workspace ws, HostInfo host)? aotFactory,
  }) : _logger = logger,
       _host = host,
       _bundleFactory = bundleFactory ?? BundleBuilder.new,
       _aotFactory = aotFactory ?? ((ws, host) => AotBuilder(ws, host: host)) {
    argParser
      ..addOption(
        'app-path',
        abbr: 'a',
        help: 'Path to the Flutter application.',
        mandatory: true,
      )
      ..addOption(
        'workspace',
        abbr: 'w',
        help: r'Workspace root (defaults to $FLUTTER_WORKSPACE or cwd).',
      )
      ..addOption(
        'mode',
        abbr: 'm',
        help: 'Runtime mode. debug is JIT (no AOT); profile/release are AOT.',
        allowed: const ['debug', 'profile', 'release'],
        defaultsTo: 'release',
      )
      ..addOption(
        'arch',
        help: 'Target arch (defaults to host). e.g. arm64 for a Raspberry Pi.',
      )
      ..addOption(
        'output',
        abbr: 'o',
        aliases: ['out'],
        help:
            'Output bundle directory, any path (defaults under the '
            'workspace).',
      )
      ..addFlag(
        'build',
        help: 'Run `emb aot` first to (re)build flutter_assets + libapp.so.',
        negatable: false,
      );
  }

  final Logger _logger;
  final HostInfo? _host;
  final BundleBuilder Function(Workspace ws) _bundleFactory;
  final AotBuilder Function(Workspace ws, HostInfo host) _aotFactory;

  @override
  String get description =>
      'Assemble an ivi-homescreen bundle from app + engine artifacts.';

  @override
  String get name => 'bundle';

  @override
  Future<int> run() async {
    final args = argResults!;
    final host = _host ?? HostInfo.detect();
    final workspace = Workspace.resolve(override: args['workspace'] as String?);
    final appPath = args['app-path'] as String;
    final mode = args['mode'] as String;
    final arch = (args['arch'] as String?) ?? host.machineArch;

    if (!Directory(appPath).existsSync()) {
      _logger.err('App path not found: $appPath');
      return ExitCode.usage.code;
    }

    final output =
        (args['output'] as String?) ??
        defaultBundleOutput(workspace, appPath, mode, arch);

    final progress = _logger.progress('Bundle $mode/$arch');
    final result = await buildAndAssemble(
      workspace: workspace,
      aot: _aotFactory(workspace, host),
      bundle: _bundleFactory(workspace),
      engine: EngineArtifacts(workspace),
      appPath: appPath,
      arch: arch,
      mode: mode,
      outputDir: output,
      build: args['build'] as bool,
      onStep: progress.update,
    );

    if (!result.success) {
      progress.fail('Bundle failed');
      if (result.message != null) _logger.err(result.message);
      for (final m in result.missing) {
        _logger.err('  - $m');
      }
      return ExitCode.software.code;
    }

    progress.complete('Bundle assembled: ${result.outputDir}');
    _logger.info('Run with: ivi-homescreen --b=${result.outputDir}');
    return ExitCode.success.code;
  }
}
