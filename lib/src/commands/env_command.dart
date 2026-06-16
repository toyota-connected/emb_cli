import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:emb_cli/src/env/env_script.dart';
import 'package:emb_cli/src/host/host_info.dart';
import 'package:emb_cli/src/workspace/workspace.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:path/path.dart' as p;

/// {@template env_command}
/// `emb env` — write `setup_env.sh` for the workspace (Flutter/Dart on PATH,
/// FLUTTER_WORKSPACE, PUB_CACHE, …). Source it with `. ./setup_env.sh`.
/// {@endtemplate}
class EnvCommand extends Command<int> {
  /// {@macro env_command}
  EnvCommand({required Logger logger, HostInfo? host})
    : _logger = logger,
      _host = host {
    argParser
      ..addOption(
        'workspace',
        abbr: 'w',
        help: r'Workspace root (defaults to $FLUTTER_WORKSPACE or cwd).',
      )
      ..addOption(
        'output',
        abbr: 'o',
        help: 'Output path (defaults to <workspace>/setup_env.sh).',
      )
      ..addFlag(
        'print',
        help: 'Print to stdout instead of writing a file.',
        negatable: false,
      );
  }

  final Logger _logger;
  final HostInfo? _host;

  @override
  String get description =>
      'Write setup_env.sh (PATH, FLUTTER_WORKSPACE, PUB_CACHE, …).';

  @override
  String get name => 'env';

  @override
  Future<int> run() async {
    final args = argResults!;
    final host = _host ?? HostInfo.detect();
    final workspace = Workspace.resolve(override: args['workspace'] as String?);

    final script = generateSetupEnv(
      workspace: workspace,
      host: host,
      engineVersion: workspace.engineCommit(),
    );

    if (args['print'] as bool) {
      _logger.info(script);
      return ExitCode.success.code;
    }

    final out =
        (args['output'] as String?) ??
        p.join(workspace.root.path, 'setup_env.sh');
    File(out).writeAsStringSync(script);
    _logger
      ..info('Wrote $out')
      ..info('Source it: . ${p.relative(out)}');
    return ExitCode.success.code;
  }
}
