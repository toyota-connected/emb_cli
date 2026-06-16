import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:emb_cli/src/flutter/flutter_sdk.dart';
import 'package:emb_cli/src/host/host_info.dart';
import 'package:emb_cli/src/workspace/workspace.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:path/path.dart' as p;

/// {@template flutter_command}
/// `emb flutter` — clone/check-out the Flutter SDK into `<workspace>/flutter`
/// at the requested version, so the engine commit (and later AOT) resolve
/// automatically.
/// {@endtemplate}
class FlutterCommand extends Command<int> {
  /// {@macro flutter_command}
  FlutterCommand({
    required Logger logger,
    HostInfo? host,
    FlutterSdk Function(Workspace ws, HostInfo host)? sdkFactory,
  }) : _logger = logger,
       _host = host,
       _sdkFactory = sdkFactory ?? ((ws, host) => FlutterSdk(ws, host: host)) {
    argParser
      ..addOption(
        'workspace',
        abbr: 'w',
        help: r'Workspace root (defaults to $FLUTTER_WORKSPACE or cwd).',
      )
      ..addOption(
        'flutter-version',
        help:
            'Flutter version/tag/branch to check out. Defaults to '
            "globals.json's flutter_version.",
      )
      ..addMultiOption(
        'config',
        abbr: 'c',
        help: 'Config directory to read globals.json from.',
        defaultsTo: const ['configs'],
      )
      ..addFlag(
        'configure',
        help:
            'Run `flutter config` (desktop + custom devices) and '
            '`flutter doctor` after install.',
        negatable: false,
      );
  }

  final Logger _logger;
  final HostInfo? _host;
  final FlutterSdk Function(Workspace ws, HostInfo host) _sdkFactory;

  @override
  String get description => 'Install the Flutter SDK into <workspace>/flutter.';

  @override
  String get name => 'flutter';

  @override
  Future<int> run() async {
    final args = argResults!;
    final host = _host ?? HostInfo.detect();
    final workspace = Workspace.resolve(override: args['workspace'] as String?);

    final version =
        (args['flutter-version'] as String?) ??
        _versionFromGlobals(args['config'] as List<String>);
    if (version == null || version.isEmpty) {
      _logger.err(
        'No Flutter version. Pass --flutter-version or provide a '
        'globals.json with "flutter_version" via --config.',
      );
      return ExitCode.usage.code;
    }

    final sdk = _sdkFactory(workspace, host);
    final progress = _logger.progress(
      'Installing Flutter SDK $version into '
      '${workspace.flutterDir.path}',
    );
    final result = await sdk.install(version);
    if (!result.success) {
      progress.fail('Flutter SDK install failed');
      if (result.message != null) _logger.err(result.message);
      return ExitCode.software.code;
    }
    progress.complete('Flutter SDK $version installed');
    if (result.engineCommit != null) {
      _logger.info('Engine commit: ${result.engineCommit}');
    } else {
      _logger.warn('Could not read engine.version from the SDK.');
    }

    if (args['configure'] as bool) {
      final cfg = _logger.progress('Configuring Flutter SDK');
      if (await sdk.configure()) {
        cfg.complete('Flutter SDK configured');
      } else {
        cfg.fail('flutter config/doctor reported a problem');
        return ExitCode.software.code;
      }
    }
    return ExitCode.success.code;
  }

  /// Read `flutter_version` from the first `globals.json` in [configDirs].
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
