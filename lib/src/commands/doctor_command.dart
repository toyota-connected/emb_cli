import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:emb_cli/src/cache/cache_dir.dart';
import 'package:emb_cli/src/cross/cargo_vendor.dart';
import 'package:emb_cli/src/cross/cross_profile.dart';
import 'package:emb_cli/src/cross/cross_project.dart';
import 'package:emb_cli/src/cross/cross_provider.dart';
import 'package:emb_cli/src/cross/cross_target.dart';
import 'package:emb_cli/src/cross/local_cross_provider.dart';
import 'package:emb_cli/src/cross/offline_enforcement.dart';
import 'package:emb_cli/src/cross/offline_probe.dart';
import 'package:emb_cli/src/cross/process_runner.dart';
import 'package:emb_cli/src/engine/engine_artifacts.dart';
import 'package:emb_cli/src/host/host_info.dart';
import 'package:emb_cli/src/host/preflight.dart';
import 'package:emb_cli/src/json_output.dart';
import 'package:emb_cli/src/manifest/manifest_loader.dart';
import 'package:emb_cli/src/pkg/host_provisioner.dart';
import 'package:emb_cli/src/workspace/workspace.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:path/path.dart' as p;

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
      )
      ..addFlag(
        'offline-probe',
        negatable: false,
        help:
            "Certify a cross target's offline build closure is materialized "
            '(toolchain, sysroot, vendored crates) without building — a '
            'seconds-scale gate. Non-zero exit if anything is missing. Pairs '
            'with --target.',
      )
      ..addFlag(
        'strict',
        negatable: false,
        help:
            'With --offline-probe: also require network isolation (unshare '
            '--net), matching what `emb cross --offline-strict` needs.',
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
    if (argResults?['offline-probe'] == true) {
      return _runOfflineProbe(
        host,
        targetArg,
        strict: argResults?['strict'] == true,
        json: json,
      );
    }
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

  /// `--offline-probe` path: certify a target's offline build closure is
  /// materialized — resolve the toolchain + sysroot from the store with the
  /// network denied, confirm each cargo module is vendored, and (under
  /// [strict]) that network isolation is available. No build runs, so it stays
  /// fast; a missing input fails with the fix (`emb fetch`).
  Future<int> _runOfflineProbe(
    HostInfo host,
    String? targetArg, {
    required bool strict,
    required bool json,
  }) async {
    final rest = argResults?.rest ?? const [];
    final inputPath = rest.isNotEmpty ? rest.first : '.';
    final CrossProject project;
    try {
      final resolved = _project.resolve(inputPath);
      if (resolved == null) {
        return _probeError('No emb manifest at $inputPath.', targetArg, json);
      }
      project = resolved;
    } on CrossProjectException catch (e) {
      return _probeError(e.message, targetArg, json);
    }

    final selection = project.selectTarget(targetArg);
    if (selection == null) {
      return _probeError(
        'Unknown target "$targetArg". '
        'Available: ${project.targets.keys.join(", ")}',
        targetArg,
        json,
      );
    }
    final CrossTarget target;
    try {
      target = CrossTarget.fromMap(selection.cross);
      // fromMap throws ArgumentError on an unknown provider token.
      // ignore: avoid_catching_errors
    } on ArgumentError catch (e) {
      return _probeError(
        'Invalid cross: block — ${e.message}',
        targetArg,
        json,
      );
    }

    final checks = <ProbeCheck>[];

    // 1. Toolchain + sysroot present in the store (offline resolve fails closed
    //    on a miss). A native target has none to fetch.
    if (!selection.isNative) {
      final provider = CrossProvider.forTarget(
        target,
        workspace: Workspace.resolve(),
        host: host,
        offline: true,
      );
      CrossResolveResult result;
      try {
        result = await provider.resolve();
      } on Object catch (e) {
        result = CrossResolveResult.failed('$e');
      }
      checks.add(
        ProbeCheck(
          'toolchain + sysroot cached',
          ok: result.ok,
          detail: result.ok
              ? ''
              : (result.message ?? 'run `emb fetch` online first'),
        ),
      );
    }

    // 2. Each cargo module's crates are vendored.
    final manifestDir =
        FileSystemEntity.typeSync(inputPath) == FileSystemEntityType.file
        ? File(inputPath).parent
        : Directory(inputPath);
    for (final m in target.modules.where((m) => m.build == ModuleBuild.cargo)) {
      final home = CargoVendor().locate(
        moduleSrc: Directory(p.join(manifestDir.path, m.path)),
        storeRoot: ensureCacheDir(),
      );
      checks.add(
        ProbeCheck(
          'cargo ${m.name} vendored',
          ok: home != null,
          detail: home != null ? '' : 'run `emb fetch`',
        ),
      );
    }

    // 3. Network isolation — required only under --strict.
    final iso = await netnsAvailable(defaultProcessRunner);
    checks.add(
      ProbeCheck(
        'network isolation',
        ok: !strict || iso,
        detail: iso
            ? 'available'
            : strict
            ? 'unavailable (required by --strict)'
            : 'unavailable (--offline-strict would refuse)',
      ),
    );

    final probe = OfflineProbe(target: selection.name, checks: checks);
    if (json) {
      _logger.info(
        jsonEnvelope(
          'doctor',
          ok: probe.ok,
          data: {'host': _hostData(host), 'offline_probe': probe.toData()},
        ),
      );
      return probe.ok ? ExitCode.success.code : ExitCode.unavailable.code;
    }

    _logger.info(styleBold.wrap('Offline probe: ${selection.name}'));
    for (final c in probe.checks) {
      final detail = c.detail.isNotEmpty ? '  (${c.detail})' : '';
      _logger.info('  ${c.ok ? "✓" : "✗"} ${c.name}$detail');
    }
    if (probe.ok) {
      _logger.success('Offline build closure is complete.');
      return ExitCode.success.code;
    }
    _logger.err('Offline build closure is incomplete — run `emb fetch`.');
    return ExitCode.unavailable.code;
  }

  int _probeError(String message, String? target, bool json) {
    if (json) {
      _logger.info(
        jsonEnvelope(
          'doctor',
          ok: false,
          data: {
            'offline_probe': {'target': target, 'error': message},
          },
        ),
      );
    } else {
      _logger.err(message);
    }
    return ExitCode.usage.code;
  }
}
