import 'package:args/command_runner.dart';
import 'package:emb_cli/src/engine/engine_artifacts.dart';
import 'package:emb_cli/src/host/host_info.dart';
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
       _provisionerFactory = provisionerFactory ?? HostProvisioner.forHost;

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
}
