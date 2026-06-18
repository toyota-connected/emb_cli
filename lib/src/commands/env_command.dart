import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:emb_cli/src/env/env_script.dart';
import 'package:emb_cli/src/host/host_info.dart';
import 'package:emb_cli/src/workspace/workspace.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:path/path.dart' as p;

/// {@template env_command}
/// `emb env` — (re)generate or print `setup_env.sh` for a workspace
/// (Flutter/Dart on PATH, FLUTTER_WORKSPACE, PUB_CACHE, …). Source it with
/// `. ./setup_env.sh`.
///
/// `emb setup` and `emb flutter` already emit this file as part of their work,
/// so the standalone command is for the cases they don't cover: regenerating
/// after the workspace has moved (the baked-in FLUTTER_WORKSPACE is absolute),
/// printing the env to stdout (`--print`), or writing it to a custom path. It
/// has no side effects beyond the one file — it never clones or installs.
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
      '(Re)generate or print setup_env.sh (PATH, FLUTTER_WORKSPACE, …).';

  @override
  String get name => 'env';

  @override
  Future<int> run() async {
    final args = argResults!;
    final host = _host ?? HostInfo.detect();
    final workspace = Workspace.resolve(override: args['workspace'] as String?);

    // The env points PATH at <workspace>/flutter; warn if no SDK is there yet
    // (e.g. `emb env` run in a bare dir), since the script will reference a
    // not-yet-present SDK. Install it with `emb flutter -w <root>`.
    if (!workspace.flutterDir.existsSync()) {
      _logger.warn(
        'No Flutter SDK at ${workspace.flutterDir.path} — the env will point '
        'at a missing SDK. Run: emb flutter -w ${workspace.root.path}',
      );
    }

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
    // Create the target dir first: `emb env -w <new path>` is a normal way to
    // seed env for a workspace that doesn't exist on disk yet.
    File(out)
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(script);
    _logger
      ..info('Wrote $out')
      ..info('Source it: . ${p.relative(out)}');
    return ExitCode.success.code;
  }
}
