import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:emb_cli/src/cache/cache_dir.dart';
import 'package:emb_cli/src/cross/cargo_vendor.dart';
import 'package:emb_cli/src/cross/cross_cache.dart';
import 'package:emb_cli/src/cross/cross_profile.dart';
import 'package:emb_cli/src/cross/cross_project.dart';
import 'package:emb_cli/src/cross/cross_provider.dart';
import 'package:emb_cli/src/cross/cross_target.dart';
import 'package:emb_cli/src/cross/emb_lock.dart';
import 'package:emb_cli/src/cross/lock_sync.dart';
import 'package:emb_cli/src/cross/process_runner.dart';
import 'package:emb_cli/src/host/host_info.dart';
import 'package:emb_cli/src/host/preflight.dart';
import 'package:emb_cli/src/manifest/manifest_loader.dart';
import 'package:emb_cli/src/step_reporter.dart';
import 'package:emb_cli/src/verbosity.dart';
import 'package:emb_cli/src/workspace/workspace.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:path/path.dart' as p;

/// {@template fetch_command}
/// `emb fetch <project|manifest> [--target <t>]` — the acquisition step of an
/// offline build. It resolves a cross target's toolchain + sysroot (including
/// the apt `-dev` closure) into the shared store and pins `emb.lock`, then
/// stops. Run it once while online; the build then runs with
/// `emb cross … --build --offline` and needs no network.
/// {@endtemplate}
class FetchCommand extends Command<int> {
  /// {@macro fetch_command}
  FetchCommand({
    required Logger logger,
    HostInfo? host,
    ManifestLoader loader = const ManifestLoader(),
    ProcessRunner? processRunner,
  }) : _logger = logger,
       _host = host,
       _project = CrossProjectResolver(loader),
       _injectedRunner = processRunner {
    argParser
      ..addOption(
        'target',
        abbr: 't',
        help:
            'Target to fetch (defaults to the manifest default; a named '
            'target for multi-target projects).',
      )
      ..addOption(
        'workspace',
        help: r'Workspace root (defaults to $FLUTTER_WORKSPACE or cwd).',
      )
      ..addOption(
        'app',
        help:
            "Also prefetch this Flutter app's pub packages "
            '(`flutter pub get --enforce-lockfile`), so an offline build has '
            'them in PUB_CACHE.',
      )
      ..addFlag(
        'update-lock',
        negatable: false,
        help:
            "Regenerate this target's emb.lock entry from the resolved "
            'toolchain/sysroot.',
      )
      ..addFlag(
        'no-verify',
        negatable: false,
        help: 'Skip emb.lock verification for this resolve.',
      );
  }

  final Logger _logger;
  final HostInfo? _host;
  final CrossProjectResolver _project;
  final ProcessRunner? _injectedRunner;

  late final ProcessRunner _runProcess =
      _injectedRunner ?? makeProcessRunner(verbosity: embVerbosity);
  late final Preflight _preflight = Preflight(_logger);
  late final LockSync _lockSync = LockSync(
    logger: _logger,
    runProcess: _runProcess,
    preflight: _preflight,
  );
  StepReporter get _steps => StepReporter(_logger);

  @override
  String get name => 'fetch';

  @override
  String get description =>
      "Fetch a cross target's toolchain + sysroot closure into the store — "
      'the online acquisition step for an offline build.';

  @override
  Future<int> run() async {
    final args = argResults!;
    if (args.rest.isEmpty) {
      _logger.err(
        'Usage: emb fetch <package-dir|manifest.yaml> [--target <t>]',
      );
      return ExitCode.usage.code;
    }

    final inputPath = args.rest.first;
    final CrossProject project;
    try {
      final resolved = _project.resolve(inputPath);
      if (resolved == null) {
        _logger.err('No emb manifest at $inputPath.');
        return ExitCode.usage.code;
      }
      project = resolved;
    } on CrossProjectException catch (e) {
      _logger.err(e.message);
      return ExitCode.usage.code;
    }

    final selection = project.selectTarget(args['target'] as String?);
    if (selection == null) {
      _logger.err(
        'Unknown target "${args['target']}". '
        'Available: ${project.targets.keys.join(", ")}',
      );
      return ExitCode.usage.code;
    }
    final CrossTarget target;
    try {
      target = CrossTarget.fromMap(selection.cross);
      // fromMap throws ArgumentError on an unknown provider token.
      // ignore: avoid_catching_errors
    } on ArgumentError catch (e) {
      _logger.err('Invalid cross: block — ${e.message}');
      return ExitCode.usage.code;
    }

    final host = _host ?? HostInfo.detect();
    final workspace = Workspace.resolve(override: args['workspace'] as String?);

    // A cross target resolves a toolchain + sysroot into the store; a native
    // (`local`/`host`) build has none, so skip straight to the cargo/pub
    // prefetch below (which an offline host build still needs).
    if (selection.isNative) {
      _logger.info(
        'Native (${selection.name}) — no toolchain/sysroot to fetch.',
      );
    } else {
      final provider = CrossProvider.forTarget(
        target,
        workspace: workspace,
        host: host,
      );

      final missing = await _preflight.missingTools(provider.preflightTools);
      if (missing.isNotEmpty) {
        _logger.err(
          'Missing host tools for ${provider.name}: ${missing.join(", ")}',
        );
        await _preflight.logInstallHint(host, missing);
        return ExitCode.unavailable.code;
      }

      // Warm the store from the shared OCI cache first (when configured), so a
      // resolve is a cache hit rather than a re-download + re-extract.
      final crossCache = CrossCache.fromEnv(
        environment: Platform.environment,
        run: _runProcess,
        logger: _logger,
      );
      final selectors = provider.cacheSelectors();
      if (crossCache != null && selectors.isNotEmpty) {
        await crossCache.pull(selectors);
      }

      final progress = _steps.start('Fetching ${provider.name} closure');
      final result = await provider.resolve();
      if (!result.ok) {
        progress.fail(result.message ?? 'resolve failed');
        return result.status == CrossResolveStatus.unavailable
            ? ExitCode.unavailable.code
            : ExitCode.software.code;
      }
      progress.complete('Fetched ${provider.name} closure');

      // Pin what resolution produced, exactly as `emb cross` does.
      if (result.lockEntry case final resolved?) {
        final isDir = FileSystemEntity.isDirectorySync(inputPath);
        final projectRoot = isDir ? inputPath : p.dirname(inputPath);
        if (!_lockSync.sync(
          projectRoot: projectRoot,
          target: lockKey(
            inputPath: inputPath,
            isDirectory: isDir,
            target: selection.name,
          ),
          resolved: resolved,
          env: await _lockSync.selfPins(workspace),
          updateLock: args['update-lock'] == true,
          verify: args['no-verify'] != true,
        )) {
          return ExitCode.software.code;
        }
      }
    }

    // Vendor cargo modules so an offline build has every crate on disk.
    if (hasCargoModules(target)) {
      if ((await _preflight.missingTools(['cargo'])).isNotEmpty) {
        _logger.err(
          'cargo not found on PATH — cannot vendor cargo modules for an '
          'offline build.',
        );
        await _preflight.logInstallHint(host, ['cargo']);
        return ExitCode.unavailable.code;
      }
      final manifestDir = FileSystemEntity.isDirectorySync(inputPath)
          ? Directory(inputPath)
          : File(inputPath).parent;
      final err = await vendorTargetCargo(
        target: target,
        manifestDir: manifestDir,
        storeRoot: ensureCacheDir(),
        run: _runProcess,
        onModule: (m) => _logger.info('  module $m: vendored cargo deps'),
      );
      if (err != null) {
        _logger.err('  $err');
        return ExitCode.software.code;
      }
    }

    // Prefetch the app's pub packages so an offline build resolves them from
    // PUB_CACHE. `--enforce-lockfile` fails rather than silently updating, and
    // populates the app's `.dart_tool` for the later build.
    if (args['app'] case final appPath?) {
      final rc = await _prefetchPub(appPath as String, host);
      if (rc != ExitCode.success.code) return rc;
    }

    _logger.success(
      'Closure ready for "${selection.name}". Build it offline with: '
      'emb cross $inputPath --target ${selection.name} --build --offline',
    );
    return ExitCode.success.code;
  }

  Future<int> _prefetchPub(String appPath, HostInfo host) async {
    final appDir = Directory(appPath);
    if (!File(p.join(appDir.path, 'pubspec.yaml')).existsSync()) {
      _logger.err('no pubspec.yaml in $appPath (is it a Flutter app?)');
      return ExitCode.usage.code;
    }
    if ((await _preflight.missingTools(['flutter'])).isNotEmpty) {
      _logger.err('flutter not found on PATH — cannot prefetch pub packages.');
      await _preflight.logInstallHint(host, ['flutter']);
      return ExitCode.unavailable.code;
    }
    final progress = _steps.start(
      'Prefetching pub packages (${p.basename(appDir.path)})',
    );
    final r = await _runProcess(
      'flutter',
      ['pub', 'get', '--enforce-lockfile'],
      workingDirectory: appDir.path,
      output: ProcessOutputMode.stream,
      label: 'pub',
    );
    if (r.exitCode != 0) {
      progress.fail('flutter pub get failed: ${r.stderr}');
      return ExitCode.software.code;
    }
    progress.complete('Prefetched pub packages');
    return ExitCode.success.code;
  }
}
