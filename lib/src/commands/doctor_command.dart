import 'package:args/command_runner.dart';
import 'package:emb_cli/src/engine/engine_artifacts.dart';
import 'package:emb_cli/src/host/host_info.dart';
import 'package:emb_cli/src/json_output.dart';
import 'package:emb_cli/src/pkg/host_provisioner.dart';
import 'package:mason_logger/mason_logger.dart';

/// {@template doctor_command}
/// `emb doctor` — report the detected host and which package backend is active.
/// {@endtemplate}
class DoctorCommand extends Command<int> {
  /// {@macro doctor_command}
  DoctorCommand({
    required Logger logger,
    HostInfo? host,
    HostProvisioner Function(HostInfo host)? provisionerFactory,
  }) : _logger = logger,
       _host = host,
       _provisionerFactory = provisionerFactory ?? HostProvisioner.forHost {
    argParser.addFlag(
      'json',
      negatable: false,
      help: 'Emit a machine-readable {schema, command, ok, data} envelope.',
    );
  }

  final Logger _logger;
  final HostInfo? _host;
  final HostProvisioner Function(HostInfo host) _provisionerFactory;

  @override
  String get description =>
      'Report host detection and package-manager backend availability.';

  @override
  String get name => 'doctor';

  @override
  Future<int> run() async {
    final host = _host ?? HostInfo.detect();
    if (argResults?['json'] == true) return _runJson(host);

    _logger
      ..info(styleBold.wrap('Host'))
      ..info('  os:        ${host.os.name}')
      ..info(
        '  arch:      ${host.machineArch} (flutter: ${host.flutterArch}, '
        'engine: ${EngineArtifacts.engineArchForHost(host)})',
      )
      ..info('  host type: ${host.hostType}')
      ..info('  version:   ${host.versionId}');
    if (host.prettyName != null) {
      _logger.info('  release:   ${host.prettyName}');
    }

    final provisioner = _provisionerFactory(host);
    _logger
      ..info('')
      ..info(styleBold.wrap('Package backend'))
      ..info('  selected:  ${provisioner.name}');

    final progress = _logger.progress('Checking ${provisioner.name}');
    try {
      final available = await provisioner.isAvailable();
      if (!available) {
        progress.fail('${provisioner.name} is not available');
        return ExitCode.unavailable.code;
      }
      progress.complete('${provisioner.name} is available');

      // Available updates — best-effort and read-only (reflects the backend's
      // last cache refresh; never fails the command).
      final updateCheck = _logger.progress('Checking for available updates');
      try {
        final updates = await provisioner.availableUpdates();
        if (updates == null) {
          updateCheck.complete(
            'update check not supported by ${provisioner.name}',
          );
        } else if (updates.isEmpty) {
          updateCheck.complete('up to date');
        } else {
          final n = updates.length;
          updateCheck.complete('$n update${n == 1 ? "" : "s"} available');
          final preview = updates.take(6).join(', ');
          _logger.info('  $preview${n > 6 ? ", …" : ""}');
        }
      } on Object {
        updateCheck.fail('update check failed');
      }
    } finally {
      await provisioner.dispose();
    }

    return ExitCode.success.code;
  }

  /// The `--json` path: compute the same host/backend facts without the text
  /// banners or spinners, and emit the envelope. `ok` is the backend
  /// availability (also the exit code), matching the text path.
  Future<int> _runJson(HostInfo host) async {
    final provisioner = _provisionerFactory(host);
    try {
      final available = await provisioner.isAvailable();
      List<String>? updates;
      var updateError = false;
      if (available) {
        try {
          updates = await provisioner.availableUpdates();
        } on Object {
          updateError = true;
        }
      }
      final data = <String, Object?>{
        'host': {
          'os': host.os.name,
          'arch': host.machineArch,
          'flutterArch': host.flutterArch,
          'engineArch': EngineArtifacts.engineArchForHost(host),
          'hostType': host.hostType,
          'version': host.versionId,
          if (host.prettyName != null) 'release': host.prettyName,
        },
        'backend': {
          'name': provisioner.name,
          'available': available,
          if (available)
            'updates': {
              if (updateError)
                'error': 'update check failed'
              else if (updates == null)
                'supported': false
              else ...{
                'supported': true,
                'count': updates.length,
                'available': updates,
              },
            },
        },
      };
      _logger.info(jsonEnvelope('doctor', ok: available, data: data));
      return available ? ExitCode.success.code : ExitCode.unavailable.code;
    } finally {
      await provisioner.dispose();
    }
  }
}
