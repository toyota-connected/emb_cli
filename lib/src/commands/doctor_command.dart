import 'package:args/command_runner.dart';
import 'package:emb_cli/src/cross/cross_project.dart';
import 'package:emb_cli/src/cross/cross_provider.dart';
import 'package:emb_cli/src/cross/cross_target.dart';
import 'package:emb_cli/src/cross/local_cross_provider.dart';
import 'package:emb_cli/src/engine/engine_artifacts.dart';
import 'package:emb_cli/src/host/host_info.dart';
import 'package:emb_cli/src/host/preflight.dart';
import 'package:emb_cli/src/json_output.dart';
import 'package:emb_cli/src/manifest/manifest_loader.dart';
import 'package:emb_cli/src/pkg/host_provisioner.dart';
import 'package:emb_cli/src/workspace/workspace.dart';
import 'package:mason_logger/mason_logger.dart';

/// {@template doctor_command}
/// `emb doctor` — report the detected host and which package backend is active.
/// With `--target <name>`, instead report a cross target's provider preflight
/// (the host tools it needs, present or missing, with an install hint).
/// {@endtemplate}
class DoctorCommand extends Command<int> {
  /// {@macro doctor_command}
  DoctorCommand({
    required Logger logger,
    HostInfo? host,
    HostProvisioner Function(HostInfo host)? provisionerFactory,
    ManifestLoader loader = const ManifestLoader(),
    Preflight? preflight,
  }) : _logger = logger,
       _host = host,
       _provisionerFactory = provisionerFactory ?? HostProvisioner.forHost,
       _project = CrossProjectResolver(loader),
       _preflight = preflight ?? Preflight(logger) {
    argParser
      ..addFlag(
        'json',
        negatable: false,
        help: 'Emit a machine-readable {schema, command, ok, data} envelope.',
      )
      ..addOption(
        'target',
        abbr: 't',
        help:
            'Report a cross target provider preflight (host tools) instead of '
            'the package backend. Resolves the manifest at the positional path '
            '(default: current directory).',
      );
  }

  final Logger _logger;
  final HostInfo? _host;
  final HostProvisioner Function(HostInfo host) _provisionerFactory;
  final CrossProjectResolver _project;
  final Preflight _preflight;

  @override
  String get description =>
      'Report host detection and package-manager backend availability.';

  @override
  String get name => 'doctor';

  @override
  Future<int> run() async {
    final host = _host ?? HostInfo.detect();
    final targetArg = argResults?['target'] as String?;
    final json = argResults?['json'] == true;
    if (targetArg != null) {
      return json
          ? _runTargetJson(host, targetArg)
          : _runTarget(host, targetArg);
    }
    if (json) return _runJson(host);

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
        'host': _hostData(host),
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

  /// The host facts, shared by the backend and target JSON paths.
  Map<String, Object?> _hostData(HostInfo host) => {
    'os': host.os.name,
    'arch': host.machineArch,
    'flutterArch': host.flutterArch,
    'engineArch': EngineArtifacts.engineArchForHost(host),
    'hostType': host.hostType,
    'version': host.versionId,
    if (host.prettyName != null) 'release': host.prettyName,
  };

  /// Resolve the manifest+[targetArg] to its [CrossProvider], or a usage error
  /// (message logged only when [logErrors]). Returns `(provider, null)` on
  /// success or `(null, exitCode)` on failure.
  Future<(CrossProvider?, int?)> _resolveProvider(
    HostInfo host,
    String targetArg, {
    required bool logErrors,
  }) async {
    final rest = argResults?.rest ?? const [];
    final inputPath = rest.isNotEmpty ? rest.first : '.';
    final CrossProject project;
    try {
      final resolved = _project.resolve(inputPath);
      if (resolved == null) {
        if (logErrors) _logger.err('No emb manifest at $inputPath.');
        return (null, ExitCode.usage.code);
      }
      project = resolved;
    } on CrossProjectException catch (e) {
      if (logErrors) _logger.err(e.message);
      return (null, ExitCode.usage.code);
    }

    final isNative = targetArg == 'local' || targetArg == 'host';
    final Map<dynamic, dynamic> selected;
    if (isNative) {
      selected = project.nativeCross;
    } else {
      final ref = project[targetArg];
      if (ref == null) {
        if (logErrors) {
          _logger.err(
            'Unknown target "$targetArg". '
            'Available: ${project.targets.keys.join(", ")}',
          );
        }
        return (null, ExitCode.usage.code);
      }
      selected = ref.cross;
    }

    final CrossTarget target;
    try {
      target = CrossTarget.fromMap(selected);
      // fromMap throws ArgumentError on an unknown provider token.
      // ignore: avoid_catching_errors
    } on ArgumentError catch (e) {
      if (logErrors) _logger.err('Invalid cross: block — ${e.message}');
      return (null, ExitCode.usage.code);
    }

    final workspace = Workspace.resolve();
    final provider = isNative
        ? LocalCrossProvider(host)
        : CrossProvider.forTarget(target, workspace: workspace, host: host);
    return (provider, null);
  }

  /// `--target` text path: resolve the target, report its provider preflight.
  Future<int> _runTarget(HostInfo host, String targetArg) async {
    final (provider, err) = await _resolveProvider(
      host,
      targetArg,
      logErrors: true,
    );
    if (provider == null) return err!;

    final missing = await _preflight.missingTools(provider.preflightTools);
    _logger
      ..info(styleBold.wrap('Target $targetArg (${provider.name})'))
      ..info(
        '  preflight: '
        '${missing.isEmpty ? "ok" : "MISSING ${missing.join(", ")}"}',
      );
    if (missing.isNotEmpty) {
      await _preflight.logInstallHint(host, missing);
      return ExitCode.unavailable.code;
    }
    return ExitCode.success.code;
  }

  /// `--target --json` path: the same preflight as a `{host, target}` envelope.
  Future<int> _runTargetJson(HostInfo host, String targetArg) async {
    final (provider, err) = await _resolveProvider(
      host,
      targetArg,
      logErrors: false,
    );
    if (provider == null) {
      _logger.info(
        jsonEnvelope(
          'doctor',
          ok: false,
          data: {
            'host': _hostData(host),
            'target': {'name': targetArg, 'error': 'unresolved'},
          },
        ),
      );
      return err!;
    }

    final missing = await _preflight.missingTools(provider.preflightTools);
    final ok = missing.isEmpty;
    _logger.info(
      jsonEnvelope(
        'doctor',
        ok: ok,
        data: {
          'host': _hostData(host),
          'target': {
            'name': targetArg,
            'provider': provider.name,
            'preflight': {'ok': ok, 'missing': missing},
          },
        },
      ),
    );
    return ok ? ExitCode.success.code : ExitCode.unavailable.code;
  }
}
