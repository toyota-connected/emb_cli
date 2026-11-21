import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:emb_cli/src/cache/cache_dir.dart';
import 'package:emb_cli/src/cross/app_prefetch.dart';
import 'package:emb_cli/src/cross/cargo_vendor.dart';
import 'package:emb_cli/src/cross/cross_arch.dart';
import 'package:emb_cli/src/cross/cross_cache.dart';
import 'package:emb_cli/src/cross/cross_profile.dart';
import 'package:emb_cli/src/cross/cross_project.dart';
import 'package:emb_cli/src/cross/cross_provider.dart';
import 'package:emb_cli/src/cross/cross_target.dart';
import 'package:emb_cli/src/cross/emb_lock.dart';
import 'package:emb_cli/src/cross/flutter_provision.dart';
import 'package:emb_cli/src/cross/lock_sync.dart';
import 'package:emb_cli/src/cross/process_runner.dart';
import 'package:emb_cli/src/cross/source_checkout.dart';
import 'package:emb_cli/src/engine/engine_artifacts.dart';
import 'package:emb_cli/src/host/host_info.dart';
import 'package:emb_cli/src/host/preflight.dart';
import 'package:emb_cli/src/manifest/manifest_loader.dart';
import 'package:emb_cli/src/repo/git_repo.dart';
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
    ToolProbe toolProbe = whichProbe,
    GitRunner sdkGitRunner = defaultGitRunner,
    EngineArtifacts Function(Workspace ws)? engineFactory,
  }) : _logger = logger,
       _engineFactory = engineFactory ?? EngineArtifacts.new,
       _gitRunner = sdkGitRunner,
       _host = host,
       _toolProbe = toolProbe,
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
        abbr: 'w',
        help:
            "Workspace root (defaults to the manifest's workspace:, then "
            r'$FLUTTER_WORKSPACE, then cwd).',
      )
      ..addOption(
        'app',
        help:
            "Prefetch this Flutter app's pub packages "
            '(`flutter pub get --enforce-lockfile`), so an offline build has '
            'them in PUB_CACHE. Replaces a declared cross.app, which is '
            'otherwise cloned and prefetched.',
      )
      ..addMultiOption(
        'mode',
        abbr: 'm',
        allowed: ['debug', 'profile', 'release'],
        defaultsTo: ['release'],
        help:
            'Runtime mode(s) the app will be built in: the engine for each is '
            'fetched. Match the --mode given to emb cross.',
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
  final ToolProbe _toolProbe;

  /// Runs git for the Flutter SDK install.
  final GitRunner _gitRunner;
  final EngineArtifacts Function(Workspace ws) _engineFactory;

  late final ProcessRunner _runProcess =
      _injectedRunner ?? makeProcessRunner(verbosity: embVerbosity);
  late final Preflight _preflight = Preflight(_logger, probe: _toolProbe);
  late final LockSync _lockSync = LockSync(
    logger: _logger,
    runProcess: _runProcess,
    preflight: _preflight,
  );
  StepReporter get _steps => StepReporter(_logger);

  /// The project at [inputPath] with unresolvable targets set aside, or null
  /// after reporting why there is none.
  CrossProject? _resolveProject(
    String inputPath, {
    Map<String, String> sourceDirs = const {},
  }) {
    try {
      final resolved = _project.resolve(
        inputPath,
        deferExtends: true,
        sourceDirs: sourceDirs,
      );
      if (resolved == null) _logger.err('No emb manifest at $inputPath.');
      return resolved;
    } on CrossProjectException catch (e) {
      _logger.err(e.message);
      return null;
    }
  }

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
    // A target whose `extends:` does not resolve is set aside: it may be
    // another target's problem, or need `cross.source` cloned first.
    var project = _resolveProject(inputPath);
    if (project == null) return ExitCode.usage.code;
    final workspace = resolveBuildWorkspace(
      project,
      override: args['workspace'] as String?,
      logger: _logger,
    );

    final targetArg = args['target'] as String?;
    var picked = project.selectTarget(targetArg);
    // The checkout of cross.source, once it has been synced.
    Directory? source;
    final pending = project.unresolved[targetArg ?? project.defaultTarget];
    if (picked == null && pending != null) {
      // `extends: 'source#<target>'` names a target inside the embedder, so
      // the embedder is fetched before the target can be resolved.
      final repo = CrossTarget.repoFrom(pending.block['source']);
      if (repo == null) {
        _logger.err(pending.message);
        return ExitCode.usage.code;
      }
      source = await syncSourceRepo(
        repo,
        workspace,
        logger: _logger,
        what: 'embedder source',
        sourcePath: pending.sourcePath,
        offline: false,
      );
      if (source == null) return ExitCode.software.code;
      project = _resolveProject(
        inputPath,
        sourceDirs: {pending.name: source.path},
      );
      if (project == null) return ExitCode.usage.code;
      picked = project.selectTarget(targetArg);
      final still = project.unresolved[pending.name];
      if (picked == null && still != null) {
        _logger.err(still.message);
        return ExitCode.usage.code;
      }
    }
    final selection = picked;
    if (selection == null) {
      _logger.err(
        'Unknown target "${args['target']}". '
        'Available: ${project.targets.keys.join(", ")}',
      );
      return ExitCode.usage.code;
    }
    final embedderRoot =
        FileSystemEntity.typeSync(inputPath) == FileSystemEntityType.file
        ? p.dirname(p.absolute(inputPath))
        : p.absolute(inputPath);

    // An offline build reuses the embedder checkout and cannot make one, so
    // a declared cross.source is part of what there is to fetch.
    final declaredSource = CrossTarget.repoFrom(selection.cross['source']);
    if (declaredSource != null && source == null) {
      source = await syncSourceRepo(
        declaredSource,
        workspace,
        logger: _logger,
        what: 'embedder source',
        sourcePath: selection.sourcePath,
        offline: false,
      );
      if (source == null) return ExitCode.software.code;
    }

    // The same goes for a declared cross.app, which `--app` replaces here as
    // it does in `emb cross`.
    var appArg = args['app'] as String?;
    final declaredApp = appArg == null
        ? CrossTarget.repoFrom(selection.cross['app'])
        : null;
    if (declaredApp != null) {
      final dir = await syncSourceRepo(
        declaredApp,
        workspace,
        logger: _logger,
        what: 'app source',
        sourcePath: selection.sourcePath,
        offline: false,
      );
      if (dir == null) return ExitCode.software.code;
      // `pubspec_path` addresses an app inside a larger repo.
      final sub = declaredApp.pubspecPath;
      appArg = sub == null || sub.isEmpty ? dir.path : p.join(dir.path, sub);
    }
    final appDir = appArg == null
        ? null
        : FileSystemEntity.typeSync(appArg) == FileSystemEntityType.file
        ? p.dirname(p.absolute(appArg))
        : p.absolute(appArg);
    // The app can add to the sysroot the build needs (a `-dev` package its
    // hooks link against), so the closure is resolved with its layer merged.
    final layer = _project.layered(selection, appDir: appArg);
    final CrossTarget target;
    try {
      target = CrossTarget.fromMap(layer.cross).withResolvedPaths(
        layer.sourcePath,
        vars: {
          'embedder_root': embedderRoot,
          'app_root': ?appDir,
        },
      );
      // fromMap throws ArgumentError on an unknown provider token.
      // ignore: avoid_catching_errors
    } on ArgumentError catch (e) {
      _logger.err('Invalid cross: block — ${e.message}');
      return ExitCode.usage.code;
    }

    final host = _host ?? HostInfo.detect();

    // `--build --offline` cannot install the SDK the manifest pins either.
    if (!await ensureFlutterSdk(
      project.flutterVersion,
      workspace,
      host: host,
      logger: _logger,
      run: _runProcess,
      offline: false,
      gitRunner: _gitRunner,
    )) {
      return ExitCode.software.code;
    }

    // A cross target resolves a toolchain + sysroot into the store; a native
    // (`local`/`host`) build has none, so skip straight to the cargo/pub
    // prefetch below (which an offline host build still needs).
    // The arch the app is built for, which names its engine.
    var engineArch = host.machineArch;
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
      if (result.profile case final profile?) {
        engineArch = archOfTriple(profile.targetTriple);
      }

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
          ? Directory(inputPath).absolute
          : File(inputPath).absolute.parent;
      final err = await vendorTargetCargo(
        target: target,
        manifestDir: manifestDir,
        storeRoot: ensureCacheDir(),
        run: _runProcess,
        appDir: appDir,
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
    if (appArg case final appPath?) {
      final rc = await prefetchAppPub(
        appPath,
        workspace,
        host: host,
        logger: _logger,
        run: _runProcess,
        preflight: _preflight,
        declared: declaredApp != null,
      );
      if (rc != ExitCode.success.code) return rc;
    }

    // The engine the bundle ships and gen_snapshot comes from is emb's own
    // download, made by the build when it is missing: fetch it here instead.
    if (appArg != null) {
      final rc = await fetchAppEngines(
        _engineFactory(workspace),
        workspace,
        arch: engineArch,
        modes: args['mode'] as List<String>,
        logger: _logger,
      );
      if (rc != ExitCode.success.code) return rc;
    }

    _logger.success(
      'Closure ready for "${selection.name}". Build it offline with: '
      'emb cross $inputPath --target ${selection.name} --build --offline',
    );
    return ExitCode.success.code;
  }
}
