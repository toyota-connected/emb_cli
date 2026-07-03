import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:emb_cli/src/aot/aot_builder.dart';
import 'package:emb_cli/src/bundle/bundle_builder.dart';
import 'package:emb_cli/src/bundle/bundle_pipeline.dart';
import 'package:emb_cli/src/cross/cargo_env.dart';
import 'package:emb_cli/src/cross/cross_arch.dart';
import 'package:emb_cli/src/cross/cross_builder.dart';
import 'package:emb_cli/src/cross/cross_cache.dart';
import 'package:emb_cli/src/cross/cross_keys.dart';
import 'package:emb_cli/src/cross/cross_profile.dart';
import 'package:emb_cli/src/cross/cross_project.dart';
import 'package:emb_cli/src/cross/cross_provider.dart';
import 'package:emb_cli/src/cross/cross_target.dart';
import 'package:emb_cli/src/cross/deb_packager.dart';
import 'package:emb_cli/src/cross/deployer.dart';
import 'package:emb_cli/src/cross/dockerfile_emitter.dart';
import 'package:emb_cli/src/cross/emb_lock.dart';
import 'package:emb_cli/src/cross/flatpak_packager.dart';
import 'package:emb_cli/src/cross/image_publisher.dart';
import 'package:emb_cli/src/cross/ipk_packager.dart';
import 'package:emb_cli/src/cross/local_cross_provider.dart';
import 'package:emb_cli/src/cross/module_stager.dart';
import 'package:emb_cli/src/cross/overlay_builder.dart';
import 'package:emb_cli/src/cross/process_runner.dart';
import 'package:emb_cli/src/cross/rpm_packager.dart';
import 'package:emb_cli/src/cross/runnable_bundle.dart';
import 'package:emb_cli/src/cross/tarball_packager.dart';
import 'package:emb_cli/src/engine/engine_artifacts.dart';
import 'package:emb_cli/src/host/host_info.dart';
import 'package:emb_cli/src/host/preflight.dart';
import 'package:emb_cli/src/json_output.dart';
import 'package:emb_cli/src/manifest/manifest_loader.dart';
import 'package:emb_cli/src/step_reporter.dart';
import 'package:emb_cli/src/verbosity.dart';
import 'package:emb_cli/src/version.dart';
import 'package:emb_cli/src/workspace/workspace.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:path/path.dart' as p;

/// {@template cross_command}
/// `emb cross <package>` — resolve a target manifest's `cross:` block into a
/// [CrossProfile] (toolchain + sysroot(s) + emitted build files), and with
/// `--prepare` also build its augment libraries into the overlay.
///
/// This is the consumer that turns the cross layer into a usable command; the
/// per-backend configure/build hangs off the resolved profile.
/// {@endtemplate}
class CrossCommand extends Command<int> {
  /// {@macro cross_command}
  CrossCommand({
    required Logger logger,
    HostInfo? host,
    ManifestLoader loader = const ManifestLoader(),
    AotBuilder Function(Workspace ws, HostInfo host)? aotFactory,
    BundleBuilder Function(Workspace ws)? bundleFactory,
    EngineArtifacts Function(Workspace ws)? engineFactory,
    ProcessRunner? processRunner,
  }) : _logger = logger,
       _host = host,
       _project = CrossProjectResolver(loader),
       _aotFactoryInjected = aotFactory,
       _bundleFactory = bundleFactory ?? BundleBuilder.new,
       _engineFactory = engineFactory ?? EngineArtifacts.new,
       _injectedRunner = processRunner {
    argParser
      ..addOption(
        'workspace',
        abbr: 'w',
        help: r'Workspace root (defaults to $FLUTTER_WORKSPACE or cwd).',
      )
      ..addFlag(
        'prepare',
        help: 'Also build augment libraries into the overlay.',
        negatable: false,
      )
      ..addFlag(
        'dry-run',
        help:
            'Report the resolution plan (provider, toolchain, sysroot, '
            'preflight, local inputs) without downloading, mounting, or ssh.',
        negatable: false,
      )
      ..addFlag(
        'json',
        help:
            'With --dry-run (implied), emit the plan as a machine-readable '
            '{schema, command, ok, data} envelope instead of text.',
        negatable: false,
      )
      ..addFlag(
        'build',
        help:
            'Configure + build the embedder under the resolved profile, one '
            'build per cross.backends entry.',
        negatable: false,
      )
      ..addOption(
        'target',
        abbr: 't',
        help:
            'Select a target (e.g. rpi5, imx93-evk): a cross.targets entry, or '
            'a per-board file under the project .emb/ directory. Omit it for '
            'the native local build.',
      )
      ..addFlag(
        'list-targets',
        help:
            'List the targets this project defines (cross.targets entries and '
            '.emb/ files), then exit.',
        negatable: false,
      )
      ..addMultiOption(
        'backend',
        help:
            'Build only the named cross.backends entries. Repeatable; '
            'defaults to every backend in the manifest.',
      )
      ..addFlag(
        'deb',
        help:
            'After building, package each backend binary into a .deb '
            '(root-free; Depends derived from the binary + sysroot).',
        negatable: false,
      )
      ..addFlag(
        'ipk',
        help:
            'After building, package each backend binary into an .ipk '
            '(opkg/OpenEmbedded) via opkg-build. Depends is explicit '
            '(cross.package.depends); arch via cross.package.ipk.arch.',
        negatable: false,
      )
      ..addFlag(
        'targz',
        help:
            'After building, package each backend binary into a relocatable '
            '.tar.gz (binary + cross.package.files at their target paths; '
            'unpack with tar -C /). No package manager needed.',
        negatable: false,
      )
      ..addFlag(
        'rpm',
        help:
            'After building, package each backend binary into an .rpm via '
            'rpmbuild. Requires cross.package.rpm.license; Requires is '
            'explicit + rpm auto-soname-deps. Needs rpmbuild on the host.',
        negatable: false,
      )
      ..addFlag(
        'flatpak',
        help:
            'After building, package each runnable bundle into a single-file '
            '.flatpak via flatpak-builder. Requires --app and a '
            'cross.package.flatpak.app_id; needs flatpak-builder + runtime.',
        negatable: false,
      )
      ..addFlag(
        'clean',
        help:
            'Remove this target build + overlay dirs (keeps the toolchain '
            'and sysroot), then exit.',
        negatable: false,
      )
      ..addFlag(
        'clean-all',
        help:
            'Also remove the downloaded/extracted toolchain + sysroot (and '
            'apt/deb caches) for this target, then exit.',
        negatable: false,
      )
      ..addOption(
        'app',
        help:
            'With --build: also build this Flutter app for the target and '
            'assemble a runnable bundle (embedder + engine + assets + libapp).',
      )
      ..addOption(
        'mode',
        abbr: 'm',
        allowed: ['debug', 'profile', 'release'],
        defaultsTo: 'release',
        help: 'Runtime mode for the --app bundle.',
      )
      ..addFlag(
        'tar',
        help: 'Also produce a .tar.gz of each runnable bundle.',
        negatable: false,
      )
      ..addOption(
        'deploy',
        help:
            'With --app: rsync each runnable bundle to <user@host> over SSH '
            '(SSH port/opts reused from cross.sysroot when device-sourced).',
      )
      ..addOption(
        'deploy-dir',
        defaultsTo: 'ivi-homescreen',
        help: 'Remote destination dir for --deploy.',
      )
      ..addFlag(
        'run',
        help:
            'Run the assembled bundle: on this host for --target local, or on '
            'the --deploy target over SSH.',
        negatable: false,
      )
      ..addFlag(
        'update-lock',
        help:
            "Regenerate this target's emb.lock entry from the resolved "
            'toolchain/sysroot (accepts intentional URL/version changes).',
        negatable: false,
      )
      ..addFlag(
        'no-verify',
        help:
            'Skip emb.lock verification for this resolve (do not fail on a '
            'drifted artifact sha or toolchain version).',
        negatable: false,
      )
      ..addFlag(
        'host-tools',
        help:
            "With --build: use the host's cmake/meson instead of the SDK's "
            '(for OE SDKs that pin an old one, e.g. AGL cmake 3.16.5). Also '
            'set via cross.host_build_tools.',
        negatable: false,
      )
      ..addFlag(
        'install-deps',
        help:
            "Install the provider's missing preflight host tools via the host "
            'package backend (PackageKit/brew) instead of erroring. Opt-in; '
            'needs privileges.',
        negatable: false,
      )
      ..addFlag(
        'dockerfile',
        help:
            'Resolve, then emit a Dockerfile (+ .dockerignore) that bakes the '
            'toolchain + sysroot into an OCI image so CI pulls instead of '
            'resolving (arm-gnu). Does not build; ignores --build.',
        negatable: false,
      )
      ..addFlag(
        'publish',
        help:
            'Resolve, emit, build, and push the toolchain image to a registry '
            '(arm-gnu); skips the build if the tag already exists. Implies the '
            '--dockerfile emit; requires --image. Auth via prior docker login.',
        negatable: false,
      )
      ..addOption(
        'image',
        help:
            'With --publish: image reference base <host>[/<path>]/<name> (the '
            'tag is appended). Registry-agnostic. e.g. '
            'ghcr.io/<org>/emb-cross-<triple>.',
      )
      ..addMultiOption(
        'tag',
        help:
            'With --publish: extra alias tag(s) to push alongside the '
            'immutable sysroot_key (which is always pushed and is the '
            'skip-on-exists target). Repeatable, e.g. --tag bookworm.',
      )
      ..addFlag(
        'force',
        help:
            'With --publish: build and push even if the tag already exists in '
            'the registry (default: skip).',
        negatable: false,
      )
      ..addFlag(
        'push',
        defaultsTo: true,
        help:
            'With --publish: push after building. Use --no-push to build the '
            'image locally only.',
      )
      ..addOption(
        'container-tool',
        help:
            'With --publish: container CLI to invoke (default: auto-detect '
            'docker, then podman).',
      );
  }

  final Logger _logger;
  final HostInfo? _host;
  final CrossProjectResolver _project;
  final AotBuilder Function(Workspace ws, HostInfo host)? _aotFactoryInjected;
  final BundleBuilder Function(Workspace ws) _bundleFactory;
  final EngineArtifacts Function(Workspace ws) _engineFactory;

  /// A test-injected runner, or null to build one from [embVerbosity] at run
  /// time (commands are constructed before their args, hence the lazy resolve).
  final ProcessRunner? _injectedRunner;

  /// The effective process runner: the injected one, else a verbosity-aware
  /// runner that streams build steps live at `-v`.
  late final ProcessRunner _runProcess =
      _injectedRunner ?? makeProcessRunner(verbosity: embVerbosity);

  /// Builds an [AotBuilder] using the injected factory, else the default wired
  /// to the verbosity-aware [_runProcess] so AOT output streams at `-v`.
  AotBuilder _makeAot(Workspace ws, HostInfo host) =>
      _aotFactoryInjected?.call(ws, host) ??
      AotBuilder(ws, host: host, runProcess: _runProcess);

  /// Progress reporter that draws spinners normally but plain banners at `-v`+,
  /// where a spinner would garble streamed toolchain output. Read fresh so it
  /// reflects the verbosity resolved after construction.
  StepReporter get _steps => StepReporter(_logger);

  /// Host-tool preflight (missing-tool probe, install hints, opt-in install),
  /// shared with `emb doctor --target`.
  late final Preflight _preflight = Preflight(_logger);

  @override
  String get name => 'cross';

  @override
  String get description =>
      'Resolve a manifest cross: block into a toolchain + sysroot profile.';

  @override
  Future<int> run() async {
    final args = argResults!;
    if (args.rest.isEmpty) {
      _logger.err('Usage: emb cross <package-dir|manifest.yaml> [--dry-run]');
      return ExitCode.usage.code;
    }

    // Accept a project directory (with a `.emb/` manifest home or a top-level
    // emb.yaml), a package directory, or an explicit manifest file (e.g.
    // examples/cross/pi5.emb.yaml).
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

    // --list-targets: print the targets this project defines, then exit.
    if (args['list-targets'] == true) {
      _listTargets(project);
      return ExitCode.success.code;
    }

    // Resolve the effective target. `local`/`host` is the native host build;
    // it is the default when selection is required but no --target is given.
    final targetArg = args['target'] as String?;
    final effectiveTarget = targetArg ?? project.defaultTarget ?? 'local';
    final isNative = effectiveTarget == 'local' || effectiveTarget == 'host';

    final Map<dynamic, dynamic> selected;
    if (isNative) {
      // Native uses the shared fields (backends / defines / package); the
      // cross-only fields (image_url, toolchain, cpu_flags) don't apply.
      selected = project.nativeCross;
    } else {
      final ref = project[effectiveTarget];
      if (ref == null) {
        _logger.err(
          'Unknown target "$effectiveTarget". '
          'Available: ${project.targets.keys.join(", ")}',
        );
        return ExitCode.usage.code;
      }
      selected = ref.cross;
    }

    final CrossTarget target;
    try {
      target = CrossTarget.fromMap(selected);
      // fromMap throws ArgumentError on an unknown provider token.
      // ignore: avoid_catching_errors
    } on ArgumentError catch (e) {
      _logger.err('Invalid cross: block — ${e.message}');
      return ExitCode.usage.code;
    }

    // Validate --backend against the manifest up front, before any download.
    final selectedBackends = args['backend'] as List<String>;
    final unknownBackends = selectedBackends.where(
      (b) => !target.backends.containsKey(b),
    );
    if (unknownBackends.isNotEmpty) {
      _logger.err(
        'Unknown backend(s): ${unknownBackends.join(", ")}. '
        'Available: ${target.backends.keys.join(", ")}',
      );
      return ExitCode.usage.code;
    }

    // --publish needs a registry target up front (before any download).
    final publishImage = args['image'] as String?;
    if (args['publish'] == true &&
        (publishImage == null || publishImage.isEmpty)) {
      _logger.err('--publish requires --image <host>[/<path>]/<name>.');
      return ExitCode.usage.code;
    }

    final host = _host ?? HostInfo.detect();
    final workspace = Workspace.resolve(override: args['workspace'] as String?);
    final provider = isNative
        ? LocalCrossProvider(host)
        : CrossProvider.forTarget(target, workspace: workspace, host: host);

    // --clean / --clean-all: remove working dirs and exit (no download).
    if (args['clean'] == true || args['clean-all'] == true) {
      return _clean(
        provider,
        target,
        workspace,
        all: args['clean-all'] == true,
      );
    }

    // --dry-run (implied by --json): report the plan without any download /
    // mount / ssh side effects, so every target validates on any host.
    if (args['dry-run'] == true || args['json'] == true) {
      if (args['json'] == true) {
        _logger.info(
          jsonEnvelope(
            'cross',
            ok: true,
            data: await _planData(provider, target, host, isNative: isNative),
          ),
        );
        return ExitCode.success.code;
      }
      if (isNative) {
        final be = target.backends.isEmpty
            ? '(plain)'
            : target.backends.keys.join(', ');
        _logger
          ..info(styleBold.wrap('Cross plan (local)'))
          ..info('  native build  : ${host.machineArch} (host toolchain)')
          ..info('  backends      : $be');
        return ExitCode.success.code;
      }
      await _plan(provider, target, host);
      return ExitCode.success.code;
    }

    // --publish fast path: the image tag is content-addressed by the manifest
    // (sysroot key + toolset), so check skip-on-exists BEFORE the resolve. When
    // the image is already published there is no need to download/extract the
    // toolchain + sysroot at all.
    if (args['publish'] == true &&
        args['force'] != true &&
        args['push'] != false &&
        provider.name == 'arm-gnu') {
      if (await _publishedAlready(
        target,
        triple: provider.triple,
        image: publishImage!,
        toolOverride: args['container-tool'] as String?,
      )) {
        return ExitCode.success.code;
      }
    }

    // Provider-declared preflight (tar/xz/rsync for arm-gnu, etc.).
    final missing = await _preflight.missingTools(provider.preflightTools);
    if (missing.isNotEmpty) {
      if (args['install-deps'] == true) {
        if (!await _preflight.install(host, provider.name, missing)) {
          return ExitCode.unavailable.code;
        }
      } else {
        _logger.err(
          'Missing host tools for ${provider.name}: ${missing.join(", ")}',
        );
        await _preflight.logInstallHint(host, missing);
        return ExitCode.unavailable.code;
      }
    }

    // When a cache registry is configured, pull the provider's shared artifacts
    // (sysroot base + toolchain) before resolving so the resolve is a store
    // cache hit instead of re-downloading + re-extracting them (the slow,
    // root-only sysroot path fails in a non-privileged container). No-op
    // without a registry or for providers with no content-addressed base, and
    // a miss simply falls through to the normal resolution.
    final crossCache = CrossCache.fromEnv(
      environment: Platform.environment,
      run: _runProcess,
      logger: _logger,
    );
    final cacheSelectors = provider.cacheSelectors();
    if (crossCache != null && cacheSelectors.isNotEmpty) {
      await crossCache.pull(cacheSelectors);
    }

    final progress = _steps.start('Resolving ${provider.name} cross profile');
    final result = await provider.resolve();
    if (!result.ok) {
      progress.fail(result.message ?? 'resolve failed');
      return result.status == CrossResolveStatus.unavailable
          ? ExitCode.unavailable.code
          : ExitCode.software.code;
    }
    final profile = result.profile!;
    progress.complete('Resolved ${provider.name}');
    _report(profile);

    // Reconcile emb.lock: pin the resolved toolchain/sysroot, or fail on drift
    // from a moved URL / changed derived-version. Only providers that capture
    // resolved facts populate lockEntry (arm-gnu today).
    if (result.lockEntry case final resolved?) {
      final isDir = FileSystemEntity.isDirectorySync(inputPath);
      final projectRoot = isDir ? inputPath : p.dirname(inputPath);
      if (!_syncLock(
        projectRoot: projectRoot,
        target: lockKey(
          inputPath: inputPath,
          isDirectory: isDir,
          target: effectiveTarget,
        ),
        resolved: resolved,
        env: await _selfPins(workspace),
        updateLock: args['update-lock'] == true,
        verify: args['no-verify'] != true,
      )) {
        return ExitCode.software.code;
      }
    }

    // --dockerfile: emit an OCI build for the resolved toolchain+sysroot, then
    // stop (don't build). arm-gnu only — its platform dir holds toolchain/ +
    // sysroot/; the Yocto providers don't lay out a self-contained dir to bake.
    if (args['dockerfile'] == true) {
      return _emitDockerfile(profile, target);
    }

    // Resolve the optional compiler-cache launcher (ccache/sccache) once, for
    // both the augment overlay and the main build.
    final launcher = await _resolveLauncher(target);

    // --publish: emit, then build + push the toolchain image to a registry.
    if (args['publish'] == true) {
      final code = await _publishImage(
        profile,
        target,
        image: args['image'] as String?,
        tags: args['tag'] as List<String>,
        force: args['force'] == true,
        push: args['push'] == true,
        toolOverride: args['container-tool'] as String?,
      );
      // Publish the shared artifacts so consuming builds pull them instead of
      // re-resolving. Best-effort (see CrossCache) and only when a cache
      // registry is configured; the image is the primary artifact.
      if (code == ExitCode.success.code &&
          crossCache != null &&
          cacheSelectors.isNotEmpty) {
        await crossCache.push(cacheSelectors);
      }
      return code;
    }

    if (args['prepare'] == true && target.augment.isNotEmpty) {
      final overlay = OverlayBuilder(
        workspace,
        profile,
        runProcess: _runProcess,
        launcher: launcher,
      );
      try {
        final ov = await overlay.build(target.augment);
        _logger.info('Overlay: ${ov.prefix}');
      } on OverlayBuildException catch (e) {
        _logger.err(e.message);
        return ExitCode.software.code;
      } finally {
        overlay.close();
      }
    }

    if (args['build'] == true) {
      if (args['flatpak'] == true && args['app'] == null) {
        _logger.err('--flatpak needs --app (a flatpak bundles the whole app).');
        return ExitCode.usage.code;
      }
      return _build(
        profile,
        target,
        workspace,
        inputPath,
        host: host,
        deb: args['deb'] == true,
        ipk: args['ipk'] == true,
        targz: args['targz'] == true,
        rpm: args['rpm'] == true,
        flatpak: args['flatpak'] == true,
        defaultName: project.id,
        selectedBackends: selectedBackends,
        appPath: args['app'] as String?,
        mode: args['mode'] as String,
        tar: args['tar'] == true,
        deployHost: args['deploy'] as String?,
        deployDir: args['deploy-dir'] as String,
        run: args['run'] == true,
        hostTools: target.hostTools || args['host-tools'] == true,
      );
    }
    return ExitCode.success.code;
  }

  /// Print the project's selectable targets (grouped by their family file when
  /// they came from a `cross.targets` block), plus the built-in native build.
  void _listTargets(CrossProject project) {
    if (project.targets.isEmpty) {
      _logger.info('Targets: (none)  (plus the built-in: local)');
      return;
    }
    _logger.info(styleBold.wrap('Targets'));
    for (final ref in project.targets.values) {
      final cross = ref.cross;
      final provider = (cross['provider'] ?? '?').toString();
      final arch = ref.arch ?? '?';
      final backends = cross['backends'];
      final be = backends is Map && backends.isNotEmpty
          ? backends.keys.join(',')
          : '(plain)';
      final group = ref.family != null ? '  [${ref.family}]' : '';
      final desc = ref.platform['description'];
      _logger.info(
        '  ${ref.name.padRight(16)} ${arch.padRight(8)} '
        '${provider.padRight(13)} $be$group'
        '${desc != null ? '  — $desc' : ''}',
      );
    }
    _logger.info(
      '  ${'local'.padRight(16)} ${'host'.padRight(8)} '
      '(native build)',
    );
  }

  /// Configure + build the embedder under [profile], one build per
  /// `cross.backends` entry (or a single plain build when none are declared).
  /// The CMake/meson source is the package directory (the manifest file's
  /// parent for a file input).
  Future<int> _build(
    CrossProfile profile,
    CrossTarget target,
    Workspace workspace,
    String inputPath, {
    required HostInfo host,
    bool deb = false,
    bool ipk = false,
    bool targz = false,
    bool rpm = false,
    bool flatpak = false,
    String defaultName = 'app',
    List<String> selectedBackends = const [],
    String? appPath,
    String mode = 'release',
    bool tar = false,
    String? deployHost,
    String deployDir = 'ivi-homescreen',
    bool run = false,
    bool hostTools = false,
  }) async {
    final source =
        FileSystemEntity.typeSync(inputPath) == FileSystemEntityType.file
        ? File(inputPath).parent
        : Directory(inputPath);

    // A native `local` build: no sysroot, host toolchain, no augment staging.
    final native = profile.providerName == 'local';

    // Resolve the optional compiler-cache launcher (ccache/sccache) once, for
    // both the augment overlay and the main build.
    final launcher = await _resolveLauncher(target);

    // --backend filters the matrix (validated in run()); merge shared
    // cross.defines into each backend (a backend define wins on a clash).
    final backends = {
      for (final e in target.backends.entries)
        if (selectedBackends.isEmpty || selectedBackends.contains(e.key))
          e.key: {...target.defines, ...e.value},
    };

    // Build any augment libraries the sysroot doesn't already satisfy (e.g.
    // libdisplay-info >= 0.2.0) into a per-workspace overlay prefix — kept out
    // of the sysroot so the sysroot can be a shared read-only store tree — and
    // layer its include/lib/pkg-config search paths onto the embedder build.
    // Native builds use the host's system libraries instead.
    var hostToolBins = const <String>[];
    OverlayPaths? overlayPaths;
    if (!native && target.augment.isNotEmpty) {
      final sw = Stopwatch()..start();
      final overlay = OverlayBuilder(
        workspace,
        profile,
        runProcess: _runProcess,
        launcher: launcher,
      );
      try {
        overlayPaths = await overlay.build(target.augment);
        hostToolBins = overlayPaths.binDirs;
      } on OverlayBuildException catch (e) {
        _logger.err('augment: ${e.message}');
        return ExitCode.software.code;
      } finally {
        overlay.close();
      }
      _logger.info(
        '  augment       : ${target.augment.map((a) => a.pkg).join(", ")} '
        'built (${_secs(sw)})',
      );
    }

    final buildRoot = workspace.ensurePlatformDir(
      'cross-build-${profile.targetTriple}-${buildKey(target)}',
    );
    // Native keeps the host compiler env; cross neutralizes it.
    final builder = CrossBuilder(
      profile,
      runProcess: _runProcess,
      neutralizeHostEnv: !native,
      hostTools: hostTools,
      hostToolBins: hostToolBins,
      launcher: launcher,
      ccacheBaseDir: workspace.root.path,
      overlay: overlayPaths,
    );

    final buildSw = Stopwatch()..start();
    final results = backends.isEmpty
        ? [
            await builder.build(
              sourceDir: source,
              buildDir: Directory('${buildRoot.path}/build'),
              generator: target.generator,
              defines: target.defines,
              cmakeArgs: target.cmakeArgs,
            ),
          ]
        : await builder.buildBackends(
            sourceDir: source,
            buildRoot: buildRoot,
            generator: target.generator,
            backends: backends,
            cmakeArgs: target.cmakeArgs,
          );
    buildSw.stop();

    for (final r in results) {
      final tag = r.backend != null ? '${r.backend}: ' : '';
      if (r.success) {
        _logger.info('  ${tag}built → ${r.buildDir}');
      } else {
        _logger.err('  $tag${r.message ?? "build failed"}');
      }
    }
    final okCount = results.where((r) => r.success).length;
    if (okCount > 0) {
      _logger.info(
        '  build         : $okCount backend(s) in ${_secs(buildSw)}',
      );
    }
    if (!results.every((r) => r.success)) return ExitCode.software.code;
    final built = results.where((r) => r.success).toList();

    // Assemble a runnable bundle (embedder + engine + assets + libapp).
    if (deployHost != null && appPath == null) {
      _logger.err('--deploy needs --app (no runnable bundle to send).');
      return ExitCode.usage.code;
    }
    if (appPath == null && target.modules.isNotEmpty) {
      _logger.warn(
        '  modules       : ${target.modules.map((m) => m.name).join(", ")} '
        'declared but no --app bundle to stage them into (add --app).',
      );
    }
    if (appPath != null) {
      final rc = await _runnable(
        profile,
        target,
        buildRoot,
        built,
        builder: builder,
        host: host,
        workspace: workspace,
        appPath: appPath,
        mode: mode,
        tar: tar,
        deployHost: deployHost,
        deployDir: deployDir,
        run: run,
        flatpak: flatpak,
        defaultName: defaultName,
        manifestDir: source,
      );
      if (rc != ExitCode.success.code) return rc;
    }

    if (deb) {
      final rc = await _packageDebs(
        profile,
        target,
        buildRoot,
        built,
        defaultName,
        source,
      );
      if (rc != ExitCode.success.code) return rc;
    }
    if (ipk) {
      final rc = await _packageIpks(
        profile,
        target,
        buildRoot,
        built,
        defaultName,
        source,
      );
      if (rc != ExitCode.success.code) return rc;
    }
    if (rpm) {
      final rc = await _packageRpms(
        profile,
        target,
        buildRoot,
        built,
        defaultName,
        source,
      );
      if (rc != ExitCode.success.code) return rc;
    }
    if (targz) {
      final rc = await _packageTarballs(
        profile,
        target,
        buildRoot,
        built,
        defaultName,
        source,
      );
      if (rc != ExitCode.success.code) return rc;
    }
    return ExitCode.success.code;
  }

  /// Remove the selected target's cross working dirs and report freed space.
  /// `--clean` keeps the expensive toolchain + sysroot (the keyed
  /// `cross-<triple>-<key>` dir); `--clean-all` ([all]) removes those plus the
  /// shared overlay sources too.
  Future<int> _clean(
    CrossProvider provider,
    CrossTarget target,
    Workspace workspace, {
    required bool all,
  }) async {
    final triple = provider.triple;
    final sk = sysrootKey(target);
    final dirs = <Directory>[
      workspace.platformDir('cross-build-$triple-${buildKey(target)}'),
      workspace.platformDir('overlay-$triple'),
      if (all) ...[
        workspace.platformDir('cross-$triple-$sk'),
        workspace.platformDir('overlay-src'),
        if (provider.name == 'yocto-sdk')
          workspace.platformDir('yocto-sdk-$sk'),
      ],
    ];

    var freed = 0;
    var removed = 0;
    for (final dir in dirs) {
      if (!dir.existsSync()) continue;
      final bytes = _dirSize(dir);
      dir.deleteSync(recursive: true);
      freed += bytes;
      removed++;
      _logger.info('  removed ${dir.path} (${_human(bytes)})');
    }
    if (removed == 0) {
      _logger.info('Nothing to clean for $triple.');
    } else {
      _logger.info('Freed ${_human(freed)}.');
      if (!all) {
        _logger.detail(
          'Kept the toolchain + sysroot; use --clean-all to remove those.',
        );
      }
    }
    return ExitCode.success.code;
  }

  /// Total size of [dir] in bytes, not following symlinks.
  int _dirSize(Directory dir) {
    var total = 0;
    for (final e in dir.listSync(recursive: true, followLinks: false)) {
      if (e is File) {
        try {
          total += e.lengthSync();
        } on FileSystemException {
          // Dangling entry mid-delete; ignore.
        }
      }
    }
    return total;
  }

  String _human(int bytes) {
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    var n = bytes.toDouble();
    var i = 0;
    while (n >= 1024 && i < units.length - 1) {
      n /= 1024;
      i++;
    }
    return '${n.toStringAsFixed(i == 0 || n >= 100 ? 0 : 1)}${units[i]}';
  }

  /// Build [appPath] for the target arch, then assemble a runnable bundle per
  /// built backend — the embedder binary beside the engine + flutter_assets +
  /// icudtl + libapp — under `<buildRoot>/runnable[-<backend>]`.
  Future<int> _runnable(
    CrossProfile profile,
    CrossTarget target,
    Directory buildRoot,
    List<CrossBuildResult> built, {
    required CrossBuilder builder,
    required HostInfo host,
    required Workspace workspace,
    required String appPath,
    required String mode,
    required bool tar,
    required Directory manifestDir,
    String? deployHost,
    String deployDir = 'ivi-homescreen',
    bool run = false,
    bool flatpak = false,
    String defaultName = 'app',
  }) async {
    final arch = EngineArtifacts.engineArch(archOfTriple(profile.targetTriple));
    // A native (`--target local`) build is host-runnable, so `--run` without
    // `--deploy` launches it here; a cross-build is not.
    final native = profile.providerName == 'local';

    // Build the app bundle once (engine fetch + AOT + assemble).
    final appBundle = Directory(
      p.join(buildRoot.path, 'app-bundle-$mode-$arch'),
    );
    final progress = _steps.start('Building app bundle ($mode/$arch)');
    final res = await buildAndAssemble(
      workspace: workspace,
      aot: _makeAot(workspace, host),
      bundle: _bundleFactory(workspace),
      engine: _engineFactory(workspace),
      appPath: appPath,
      arch: arch,
      mode: mode,
      outputDir: appBundle.path,
      build: true,
      onStep: progress.update,
    );
    if (!res.success) {
      progress.fail(res.message ?? 'app bundle build failed');
      return ExitCode.software.code;
    }
    progress.complete('App bundle ready → ${res.outputDir}');

    // Build any app-owned native modules once and stage their declared `.so`
    // artifacts into the bundle's lib/ (next to libapp.so). Done before the
    // per-backend copy below, so `_copyTree` propagates them to every runnable
    // dir, tarball, flatpak, and deploy.
    if (target.modules.isNotEmpty) {
      final libDir = Directory(p.join(appBundle.path, 'lib'))
        ..createSync(recursive: true);
      final ok = await _buildModules(
        builder,
        profile,
        host,
        target,
        manifestDir,
        buildRoot,
        libDir,
      );
      if (!ok) return ExitCode.software.code;
    }

    final runnable = RunnableBundle();
    for (final r in built) {
      final binary = _artifactFor(r.buildDir, target.package?.bin);
      if (binary == null) {
        _logger.err(
          '  ${r.backend ?? ""}: no embedder binary in ${r.buildDir} '
          '(set cross.package.bin)',
        );
        return ExitCode.software.code;
      }
      final multi = built.length > 1 && r.backend != null;
      final outDir = Directory(
        p.join(buildRoot.path, multi ? 'runnable-${r.backend}' : 'runnable'),
      );
      if (outDir.existsSync()) outDir.deleteSync(recursive: true);
      await _copyTree(appBundle, outDir);
      try {
        final bin = await runnable.install(binary, outDir);
        _logger.info(
          '  ${r.backend ?? ""}: runnable → ${outDir.path}  '
          '(run: ./${p.basename(bin.path)} -b .)',
        );
        if (tar) {
          final archive = await runnable.tar(outDir);
          _logger.info('  ${r.backend ?? ""}: ${archive.path}');
        }
        if (flatpak) {
          final rc = await _packageFlatpak(
            profile,
            target,
            buildRoot,
            outDir,
            embedder: p.basename(bin.path),
            backend: r.backend,
            multi: multi,
            defaultName: defaultName,
            manifestDir: manifestDir,
          );
          if (rc != ExitCode.success.code) return rc;
        }
        if (deployHost != null) {
          final dest = multi ? '$deployDir/${r.backend}' : deployDir;
          final rc = await _deploy(
            outDir,
            binName: p.basename(bin.path),
            host: deployHost,
            destDir: dest,
            spec: target.sysroot,
            bundleArch: archOfTriple(profile.targetTriple),
            // Auto-run only makes sense for a single embedder.
            run: run && built.length == 1,
          );
          if (rc != ExitCode.success.code) return rc;
        } else if (run && built.length == 1) {
          // No --deploy: launch the freshly-built embedder against the app
          // bundle on this host. Only a native (--target local) build is
          // host-runnable; a cross-build would hit `Exec format error`.
          if (native) {
            final rc = await _runLocal(binary, appBundle);
            if (rc != ExitCode.success.code) return rc;
          } else {
            _logger.warn(
              '  --run without --deploy only runs a native (--target local) '
              'build; skipping this ${archOfTriple(profile.targetTriple)} '
              'cross-build.',
            );
          }
        }
      } on RunnableBundleException catch (e) {
        _logger.err('  ${r.backend ?? ""}: ${e.message}');
        return ExitCode.software.code;
      }
    }
    return ExitCode.success.code;
  }

  /// rsync [outDir] to [host]:[destDir] over SSH, then optionally run the
  /// embedder there. SSH port/opts come from a device-sourced [spec].
  Future<int> _deploy(
    Directory outDir, {
    required String binName,
    required String host,
    required String destDir,
    required SysrootSpec? spec,
    required String bundleArch,
    required bool run,
  }) async {
    final deployer = Deployer(runProcess: _runProcess);
    final device = spec?.source == SysrootProvenance.device;
    final port = device ? spec!.sshPort : 22;
    final opts = device ? spec!.sshOpts : null;

    // Catch the common footgun: pushing a wrong-arch bundle (e.g. a native
    // `--target local` build) to the board, which only fails at run time with
    // a cryptic `Exec format error`.
    final boardArch = await deployer.remoteArch(host, port: port, opts: opts);
    if (boardArch != null && !archMatches(bundleArch, boardArch)) {
      _logger.warn(
        'bundle arch is $bundleArch but $host reports $boardArch — '
        'the embedder will not run there. Re-build with a matching '
        '--target (cross sysroot) for this board.',
      );
    }

    final progress = _steps.start('Deploying → $host:$destDir');
    final res = await deployer.push(
      outDir,
      host: host,
      destDir: destDir,
      port: port,
      opts: opts,
    );
    if (!res.success) {
      progress.fail(res.message ?? 'deploy failed');
      return ExitCode.software.code;
    }
    progress.complete('Deployed → $host:$destDir (via ${res.method})');
    final runCmd = './$binName -b .';
    if (!run) {
      _logger.info('  run on target: ssh $host "cd $destDir && $runCmd"');
      return ExitCode.success.code;
    }
    _logger.info('  running on $host …');
    final argv = deployer.runArgv(
      host,
      destDir,
      runCmd,
      port: port,
      opts: opts,
    );
    final proc = await Process.start(
      argv.first,
      argv.sublist(1),
      mode: ProcessStartMode.inheritStdio,
    );
    return proc.exitCode;
  }

  /// Launch the native [embedder] against [bundle] on this host
  /// (`<embedder> -b <bundle>`), inheriting stdio. Used by `--run` for a
  /// `--target local` build, where there is no deploy step.
  Future<int> _runLocal(File embedder, Directory bundle) async {
    final argv = [embedder.path, '-b', bundle.path];
    _logger.info('  running ${argv.join(' ')} …');
    final proc = await Process.start(
      argv.first,
      argv.sublist(1),
      mode: ProcessStartMode.inheritStdio,
    );
    return proc.exitCode;
  }

  /// Recursively copy the contents of [src] into [dst] (preserving symlinks +
  /// mode), via `cp -a`.
  Future<void> _copyTree(Directory src, Directory dst) async {
    dst.createSync(recursive: true);
    final r = await Process.run('cp', [
      '-a',
      '.',
      dst.path,
    ], workingDirectory: src.path);
    if (r.exitCode != 0) {
      throw RunnableBundleException('copy failed: ${r.stderr}');
    }
  }

  /// Package each successfully-built backend binary into a `.deb` under
  /// `<buildRoot>/dist`. Multiple backends get a `-<backend>` name suffix.
  Future<int> _packageDebs(
    CrossProfile profile,
    CrossTarget target,
    Directory buildRoot,
    List<CrossBuildResult> built,
    String defaultName,
    Directory manifestDir,
  ) async {
    final spec = target.package ?? const PackageSpec();
    final arch = debianArch(profile.targetTriple);
    final baseName = spec.name ?? defaultName;
    final outDir = Directory(p.join(buildRoot.path, 'dist'));
    // The resolver's downloaded `.deb`s sit beside the sysroot, in `debs/`.
    final debDirs = [
      Directory(p.join(p.dirname(profile.targetSysroot), 'debs')),
    ];
    // Extra files resolved against the manifest dir → absolute target paths.
    final ef = _extraFiles(spec, manifestDir);
    // Maintainer scripts (preinst/postinst/prerm/postrm) → DEBIAN/<name>.
    final maintainerScripts = {
      for (final e in spec.scripts.entries)
        e.key: p.join(manifestDir.path, e.value),
    };
    final packager = DebPackager(
      readelf: _readelfFor(profile),
      runProcess: _runProcess,
    );

    for (final r in built) {
      final binary = _artifactFor(r.buildDir, spec.bin);
      if (binary == null) {
        _logger.err(
          '  ${r.backend ?? ""}: no binary to package in ${r.buildDir} '
          '(set cross.package.bin)',
        );
        return ExitCode.software.code;
      }
      final multi = built.length > 1 && r.backend != null;
      final name = multi ? '$baseName-${r.backend}' : baseName;
      final meta = DebMetadata(
        name: name,
        version: spec.version,
        architecture: arch,
        maintainer: spec.maintainer,
        description: spec.description ?? '$name (cross-built by emb for $arch)',
        section: spec.section,
        priority: spec.priority,
        dependsExtra: spec.depends,
        autoDepends: spec.autoDepends,
      );
      try {
        final out = await packager.build(
          binary: binary,
          installPath: p.join(spec.installDir, p.basename(binary.path)),
          meta: meta,
          outDir: outDir,
          sysroot: Directory(profile.targetSysroot),
          debDirs: debDirs,
          extraFiles: ef.files,
          fileModes: ef.modes,
          maintainerScripts: maintainerScripts,
        );
        _logger.info('  ${r.backend ?? ""}: packaged → ${out.path}');
      } on DebPackageException catch (e) {
        _logger.err('  ${r.backend ?? ""}: ${e.message}');
        return ExitCode.software.code;
      }
    }
    return ExitCode.success.code;
  }

  /// Package each successfully-built backend binary into an `.ipk` under
  /// `<buildRoot>/dist`, via opkg-build. Like `--deb` but for opkg/OE targets:
  /// `Depends` is explicit (`cross.package.depends`), and the opkg arch comes
  /// from `cross.package.ipk.arch` or a CPU-arch default. The shared
  /// `files:`/`scripts:` apply.
  Future<int> _packageIpks(
    CrossProfile profile,
    CrossTarget target,
    Directory buildRoot,
    List<CrossBuildResult> built,
    String defaultName,
    Directory manifestDir,
  ) async {
    final spec = target.package ?? const PackageSpec();
    final arch = spec.ipk?.arch ?? opkgArch(profile.targetTriple);
    final baseName = spec.name ?? defaultName;
    final outDir = Directory(p.join(buildRoot.path, 'dist'));
    final ef = _extraFiles(spec, manifestDir);
    final maintainerScripts = {
      for (final e in spec.scripts.entries)
        e.key: p.join(manifestDir.path, e.value),
    };
    final packager = IpkPackager(runProcess: _runProcess);

    for (final r in built) {
      final binary = _artifactFor(r.buildDir, spec.bin);
      if (binary == null) {
        _logger.err(
          '  ${r.backend ?? ""}: no binary to package in ${r.buildDir} '
          '(set cross.package.bin)',
        );
        return ExitCode.software.code;
      }
      final multi = built.length > 1 && r.backend != null;
      final name = multi ? '$baseName-${r.backend}' : baseName;
      final meta = IpkMetadata(
        name: name,
        version: spec.version,
        architecture: arch,
        maintainer: spec.maintainer,
        description: spec.description ?? '$name (cross-built by emb for $arch)',
        section: spec.section,
        priority: spec.priority,
        depends: spec.depends,
      );
      try {
        final out = await packager.build(
          binary: binary,
          installPath: p.join(spec.installDir, p.basename(binary.path)),
          meta: meta,
          outDir: outDir,
          extraFiles: ef.files,
          fileModes: ef.modes,
          maintainerScripts: maintainerScripts,
        );
        _logger.info('  ${r.backend ?? ""}: packaged → ${out.path}');
      } on IpkPackageException catch (e) {
        _logger.err('  ${r.backend ?? ""}: ${e.message}');
        return ExitCode.software.code;
      }
    }
    return ExitCode.success.code;
  }

  /// Package each successfully-built backend binary into an `.rpm` under
  /// `<buildRoot>/dist`, via rpmbuild. `License` (required) and `release`/`group`
  /// come from `cross.package.rpm`; `Requires` is explicit (`depends`) plus
  /// rpm's automatic soname deps. The shared `files:`/`scripts:` apply.
  Future<int> _packageRpms(
    CrossProfile profile,
    CrossTarget target,
    Directory buildRoot,
    List<CrossBuildResult> built,
    String defaultName,
    Directory manifestDir,
  ) async {
    final spec = target.package ?? const PackageSpec();
    final rpmSpec = spec.rpm;
    if (rpmSpec?.license == null) {
      _logger.err(
        '  --rpm needs cross.package.rpm.license (rpm refuses to build '
        'without a License tag).',
      );
      return ExitCode.usage.code;
    }
    final arch = rpmArch(profile.targetTriple);
    final baseName = spec.name ?? defaultName;
    final outDir = Directory(p.join(buildRoot.path, 'dist'));
    final ef = _extraFiles(spec, manifestDir);
    final scriptlets = {
      for (final e in spec.scripts.entries)
        e.key: p.join(manifestDir.path, e.value),
    };
    final packager = RpmPackager(runProcess: _runProcess);

    for (final r in built) {
      final binary = _artifactFor(r.buildDir, spec.bin);
      if (binary == null) {
        _logger.err(
          '  ${r.backend ?? ""}: no binary to package in ${r.buildDir} '
          '(set cross.package.bin)',
        );
        return ExitCode.software.code;
      }
      final multi = built.length > 1 && r.backend != null;
      final name = multi ? '$baseName-${r.backend}' : baseName;
      final meta = RpmMetadata(
        name: name,
        version: spec.version,
        architecture: arch,
        license: rpmSpec!.license!,
        summary: spec.description ?? '$name (cross-built by emb for $arch)',
        release: rpmSpec.release,
        group: rpmSpec.group,
        requires: spec.depends,
        scriptlets: scriptlets,
      );
      try {
        final out = await packager.build(
          binary: binary,
          installPath: p.join(spec.installDir, p.basename(binary.path)),
          meta: meta,
          outDir: outDir,
          extraFiles: ef.files,
          fileModes: ef.modes,
        );
        _logger.info('  ${r.backend ?? ""}: packaged → ${out.path}');
      } on RpmPackageException catch (e) {
        _logger.err('  ${r.backend ?? ""}: ${e.message}');
        return ExitCode.software.code;
      }
    }
    return ExitCode.success.code;
  }

  /// Package each successfully-built backend binary into a relocatable
  /// `.tar.gz` under `<buildRoot>/dist`. Honours the shared `files:` map;
  /// `scripts:` do not apply (nothing runs them on extraction) and are warned.
  Future<int> _packageTarballs(
    CrossProfile profile,
    CrossTarget target,
    Directory buildRoot,
    List<CrossBuildResult> built,
    String defaultName,
    Directory manifestDir,
  ) async {
    final spec = target.package ?? const PackageSpec();
    if (spec.scripts.isNotEmpty) {
      _logger.warn(
        '  --targz: cross.package.scripts is ignored (a tarball has no '
        'installer to run maintainer scripts).',
      );
    }
    final arch = archOfTriple(profile.targetTriple);
    final baseName = spec.name ?? defaultName;
    final outDir = Directory(p.join(buildRoot.path, 'dist'));
    final ef = _extraFiles(spec, manifestDir);
    final packager = TarballPackager(runProcess: _runProcess);

    for (final r in built) {
      final binary = _artifactFor(r.buildDir, spec.bin);
      if (binary == null) {
        _logger.err(
          '  ${r.backend ?? ""}: no binary to package in ${r.buildDir} '
          '(set cross.package.bin)',
        );
        return ExitCode.software.code;
      }
      final multi = built.length > 1 && r.backend != null;
      final name = multi ? '$baseName-${r.backend}' : baseName;
      final meta = TarballMetadata(
        name: name,
        version: spec.version,
        architecture: arch,
      );
      try {
        final out = await packager.build(
          binary: binary,
          installPath: p.join(spec.installDir, p.basename(binary.path)),
          meta: meta,
          outDir: outDir,
          extraFiles: ef.files,
          fileModes: ef.modes,
        );
        _logger.info('  ${r.backend ?? ""}: packaged → ${out.path}');
      } on TarballPackageException catch (e) {
        _logger.err('  ${r.backend ?? ""}: ${e.message}');
        return ExitCode.software.code;
      }
    }
    return ExitCode.success.code;
  }

  /// Package an assembled runnable [bundleDir] into a single-file `.flatpak`
  /// under `<buildRoot>/dist`, via flatpak-builder. The app id comes from
  /// `cross.package.flatpak.app_id` (required); sandbox perms, runtime, and the
  /// shared `files:` map come from the same `package:` block.
  Future<int> _packageFlatpak(
    CrossProfile profile,
    CrossTarget target,
    Directory buildRoot,
    Directory bundleDir, {
    required String embedder,
    required String? backend,
    required bool multi,
    required String defaultName,
    required Directory manifestDir,
  }) async {
    final tag = backend != null ? '$backend: ' : '';
    final spec = target.package ?? const PackageSpec();
    final fp = spec.flatpak;
    if (fp?.appId == null) {
      _logger.err(
        '  $tag--flatpak needs cross.package.flatpak.app_id '
        '(reverse-DNS, e.g. com.example.App).',
      );
      return ExitCode.usage.code;
    }
    // Distinct app ids per backend so multi-backend bundles do not collide.
    final baseId = fp!.appId!;
    final appId = multi ? '$baseId.$backend' : baseId;
    final fpArch = flatpakArch(profile.targetTriple);
    final iconRel = fp.icon;
    final icon = iconRel != null
        ? File(p.join(manifestDir.path, iconRel))
        : null;
    final ef = _extraFiles(spec, manifestDir);
    final meta = FlatpakMetadata(
      appId: appId,
      command: embedder,
      branch: fp.branch,
      runtime: fp.runtime,
      runtimeVersion: fp.runtimeVersion,
      sdk: fp.sdk,
      arch: fpArch,
      finishArgs: fp.finishArgs.isNotEmpty
          ? fp.finishArgs
          : FlatpakMetadata.defaultFinishArgs,
      appName: spec.name ?? defaultName,
      icon: icon,
      categories: fp.categories,
    );
    final outDir = Directory(p.join(buildRoot.path, 'dist'));
    final progress = _steps.start('${tag}Packaging flatpak ($appId)');
    try {
      final out = await FlatpakPackager(runProcess: _runProcess).build(
        bundleDir: bundleDir,
        meta: meta,
        outDir: outDir,
        extraFiles: ef.files,
        fileModes: ef.modes,
      );
      progress.complete('${tag}flatpak → ${out.path}');
      return ExitCode.success.code;
    } on FlatpakPackageException catch (e) {
      progress.fail('$tag${e.message}');
      return ExitCode.software.code;
    }
  }

  /// Resolve [spec]'s `files:` against [manifestDir] into a (host source →
  /// dest) map and a (host source → octal mode) map. The mode is the entry's
  /// explicit `mode:`, else the source file's own mode (so an executable stays
  /// executable and a shared object stays 0644 without spelling it out).
  ({Map<String, String> files, Map<String, String> modes}) _extraFiles(
    PackageSpec spec,
    Directory manifestDir,
  ) {
    final files = <String, String>{};
    final modes = <String, String>{};
    for (final e in spec.files.entries) {
      final src = p.join(manifestDir.path, e.key);
      files[src] = e.value;
      final f = File(src);
      final mode = spec.fileModes[e.key] ?? (f.existsSync() ? _octal(f) : null);
      if (mode != null) modes[src] = mode;
    }
    return (files: files, modes: modes);
  }

  /// The file's permission bits as a 4-digit octal string (e.g. `0755`).
  String _octal(File f) =>
      '0${(f.statSync().mode & 0x1FF).toRadixString(8).padLeft(3, '0')}';

  /// The binary to package: [bin] resolved under [buildDir], else the first ELF
  /// executable found there.
  File? _artifactFor(String buildDir, String? bin) {
    if (bin != null) {
      final f = File(p.join(buildDir, bin));
      return f.existsSync() ? f : null;
    }
    for (final e in Directory(buildDir).listSync(recursive: true)) {
      if (e is! File) continue;
      // Skip CMake's internal compiler-probe binaries (CMakeFiles/**): they are
      // ELF executables too and would otherwise shadow the real embedder.
      if (p.split(e.path).contains('CMakeFiles')) continue;
      final stat = e.statSync();
      // Executable bit + ELF magic.
      if (stat.mode & 0x49 == 0) continue;
      final head = e.openSync()..setPositionSync(0);
      final magic = head.readSync(4);
      head.closeSync();
      if (magic.length == 4 &&
          magic[0] == 0x7f &&
          magic[1] == 0x45 &&
          magic[2] == 0x4c &&
          magic[3] == 0x46) {
        return e;
      }
    }
    return null;
  }

  /// Build each app-owned [CrossTarget.modules] entry against the embedder's
  /// cross toolchain ([builder]) and stage its declared `.so` artifacts into
  /// [libDir] (the app bundle's `lib/`). Returns false — with an error logged —
  /// on any build failure or missing declared artifact.
  Future<bool> _buildModules(
    CrossBuilder builder,
    CrossProfile profile,
    HostInfo host,
    CrossTarget target,
    Directory manifestDir,
    Directory buildRoot,
    Directory libDir,
  ) async {
    for (final m in target.modules) {
      final src = Directory(p.join(manifestDir.path, m.path));
      if (!src.existsSync()) {
        _logger.err('  module ${m.name}: source dir not found: ${src.path}');
        return false;
      }
      final buildDir = Directory(p.join(buildRoot.path, 'module-${m.name}'));
      final sw = Stopwatch()..start();

      final gen = m.build.generator;
      final Directory artifactDir;
      if (gen != null) {
        // cmake/meson: reuse the embedder's cross toolchain via CrossBuilder.
        final r = await builder.build(
          sourceDir: src,
          buildDir: buildDir,
          generator: gen,
          defines: m.defines,
        );
        if (!r.success) {
          _logger.err('  module ${m.name}: ${r.message ?? "build failed"}');
          return false;
        }
        artifactDir = Directory(r.buildDir);
      } else {
        // cargo: synthesize the cross env from the profile and run cargo.
        final dir = await _cargoModule(profile, host, m, src, buildDir);
        if (dir == null) return false;
        artifactDir = dir;
      }

      for (final soname in m.artifacts) {
        final staged = stageSharedLibrary(
          soname: soname,
          buildDir: artifactDir,
          libDir: libDir,
        );
        if (staged == null) {
          _logger.err(
            '  module ${m.name}: artifact "$soname" not found under '
            '${artifactDir.path}',
          );
          return false;
        }
      }
      _logger.info(
        '  module ${m.name}: ${m.artifacts.join(", ")} → lib/ (${_secs(sw)})',
      );
    }
    return true;
  }

  /// Cross-compile a `build: cargo` module for the profile's Rust target and
  /// return the release dir holding its artifacts, or null (error logged) on a
  /// missing `cargo`, an uninstallable target, or a build failure.
  Future<Directory?> _cargoModule(
    CrossProfile profile,
    HostInfo host,
    ModuleSpec m,
    Directory src,
    Directory buildDir,
  ) async {
    if ((await _preflight.missingTools(['cargo'])).isNotEmpty) {
      _logger.err('  module ${m.name}: cargo not found on PATH');
      await _preflight.logInstallHint(host, ['cargo']);
      return null;
    }
    final triple = rustTriple(profile.targetTriple);
    final env = {
      ...cargoEnv(profile, triple),
      'CARGO_TARGET_DIR': buildDir.path,
    };
    // Best-effort: install the target's std (idempotent; no-op without rustup).
    try {
      await _runProcess('rustup', ['target', 'add', triple]);
    } on ProcessException {
      // No rustup — assume the target std is present, else cargo will error.
    }
    final r = await _runProcess(
      'cargo',
      [
        'build',
        '--release',
        '--target',
        triple,
        if (m.features.isNotEmpty) ...['--features', m.features.join(',')],
      ],
      workingDirectory: src.path,
      environment: env,
      output: ProcessOutputMode.stream,
      label: 'cargo:${m.name}',
    );
    if (r.exitCode != 0) {
      _logger.err('  module ${m.name}: cargo build failed: ${r.stderr}');
      return null;
    }
    return Directory(p.join(buildDir.path, triple, 'release'));
  }

  /// Derive the cross `readelf` path from the profile's `gcc`.
  String _readelfFor(CrossProfile profile) =>
      profile.cc.replaceFirst(RegExp(r'gcc$'), 'readelf');

  void _report(CrossProfile p) {
    _logger
      ..info(styleBold.wrap('Cross profile (${p.providerName})'))
      ..info('  triple        : ${p.targetTriple}')
      ..info('  cc            : ${p.cc}')
      ..info('  target sysroot: ${p.targetSysroot}')
      ..info('  native sysroot: ${p.nativeSysroot ?? "-"}')
      ..info('  cmake tc file : ${p.cmakeToolchainFile ?? "(emit)"}')
      ..info('  meson cross   : ${p.mesonCrossFile ?? "(emit/none)"}')
      ..info('  cpu flags     : ${p.cFlags.join(" ")}');
  }

  /// Report the resolution plan with no download / mount / ssh side effects.
  Future<void> _plan(
    CrossProvider provider,
    CrossTarget target,
    HostInfo host,
  ) async {
    final missing = await _preflight.missingTools(provider.preflightTools);
    _logger
      ..info(styleBold.wrap('Cross plan (${provider.name})'))
      ..info('  triple        : ${target.triple ?? "(provider default)"}')
      ..info('  cpu flags     : ${target.cpuFlags.join(" ")}')
      ..info('  host          : ${host.os.name}/${host.machineArch}')
      ..info(
        '  preflight     : '
        '${missing.isEmpty ? "ok" : "MISSING ${missing.join(", ")}"}',
      );
    if (missing.isNotEmpty) await _preflight.logInstallHint(host, missing);
    switch (target.provider) {
      case CrossProviderKind.armGnu:
        final tc = target.versionPolicy == ToolchainVersionPolicy.pinned
            ? (target.toolchainVersion ?? '(unset!)')
            : 'derive from sysroot codename';
        final s = target.sysroot;
        final sysroot = switch (s?.source) {
          SysrootProvenance.image => 'image  ${s?.imageUrl}',
          SysrootProvenance.device =>
            'device ${s?.deviceHost} (ssh:${s?.sshPort})',
          null => '(none configured)',
        };
        _logger
          ..info('  toolchain     : $tc')
          ..info('  sysroot       : $sysroot');
        if (host.os != HostOs.linux) {
          _logger.info('  note          : resolve needs a Linux host + root');
        }
      case CrossProviderKind.yoctoRecipe:
        final build = target.yoctoBuild;
        final present = build != null && Directory(build).existsSync();
        _logger
          ..info(
            '  recipe        : ${target.recipe} @ ${build ?? "(unset!)"} '
            '${present ? "[present]" : "[absent]"}',
          )
          ..info('  machine tuple : ${target.machineTuple ?? "(unset!)"}');
      case CrossProviderKind.yoctoSdk:
        final loc = target.sdkEnvSetup ?? target.sdkPath ?? target.sdkUrl;
        final isUrl =
            target.sdkUrl != null &&
            target.sdkPath == null &&
            target.sdkEnvSetup == null;
        final present = target.sdkEnvSetup != null
            ? File(target.sdkEnvSetup!).existsSync()
            : target.sdkPath != null && Directory(target.sdkPath!).existsSync();
        final state = isUrl
            ? '[download]'
            : (present ? '[present]' : '[absent]');
        _logger.info('  sdk           : ${loc ?? "(none!)"} $state');
    }
    if (target.augment.isNotEmpty) {
      _logger.info(
        '  augment       : ${target.augment.map((a) => a.pkg).join(", ")}',
      );
    }
    if (target.backends.isNotEmpty) {
      _logger.info(
        '  backends      : ${target.backends.keys.join(", ")} '
        '(${target.generator.name})',
      );
    }
    if (target.launcher != Launcher.none) {
      final exe = target.launcher.exe!;
      final found = (await _preflight.missingTools([exe])).isEmpty;
      _logger.info('  launcher      : $exe${found ? "" : " (not found)"}');
    }
  }

  /// The dry-run plan as a JSON-serializable map — the same facts [_plan]
  /// renders as text, for `--json`.
  Future<Map<String, Object?>> _planData(
    CrossProvider provider,
    CrossTarget target,
    HostInfo host, {
    required bool isNative,
  }) async {
    if (isNative) {
      return {
        'native': true,
        'arch': host.machineArch,
        'backends': target.backends.keys.toList(),
        'generator': target.generator.name,
      };
    }
    final missing = await _preflight.missingTools(provider.preflightTools);
    final data = <String, Object?>{
      'provider': provider.name,
      'triple': target.triple,
      'cpuFlags': target.cpuFlags,
      'host': {'os': host.os.name, 'arch': host.machineArch},
      'preflight': {'ok': missing.isEmpty, 'missing': missing},
    };
    switch (target.provider) {
      case CrossProviderKind.armGnu:
        data['toolchain'] =
            target.versionPolicy == ToolchainVersionPolicy.pinned
            ? target.toolchainVersion
            : 'derive-from-sysroot';
        final s = target.sysroot;
        data['sysroot'] = switch (s?.source) {
          SysrootProvenance.image => {
            'source': 'image',
            'imageUrl': s?.imageUrl,
          },
          SysrootProvenance.device => {
            'source': 'device',
            'host': s?.deviceHost,
            'sshPort': s?.sshPort,
          },
          null => null,
        };
      case CrossProviderKind.yoctoRecipe:
        final build = target.yoctoBuild;
        data['recipe'] = target.recipe;
        data['build'] = build;
        data['buildPresent'] = build != null && Directory(build).existsSync();
        data['machineTuple'] = target.machineTuple;
      case CrossProviderKind.yoctoSdk:
        final isUrl =
            target.sdkUrl != null &&
            target.sdkPath == null &&
            target.sdkEnvSetup == null;
        final present = target.sdkEnvSetup != null
            ? File(target.sdkEnvSetup!).existsSync()
            : target.sdkPath != null && Directory(target.sdkPath!).existsSync();
        data['sdk'] = target.sdkEnvSetup ?? target.sdkPath ?? target.sdkUrl;
        data['sdkState'] = isUrl
            ? 'download'
            : (present ? 'present' : 'absent');
    }
    if (target.augment.isNotEmpty) {
      data['augment'] = target.augment.map((a) => a.pkg).toList();
    }
    if (target.backends.isNotEmpty) {
      data['backends'] = target.backends.keys.toList();
      data['generator'] = target.generator.name;
    }
    if (target.launcher != Launcher.none) {
      final exe = target.launcher.exe!;
      data['launcher'] = {
        'name': exe,
        'found': (await _preflight.missingTools([exe])).isEmpty,
      };
    }
    return data;
  }

  /// A stopwatch rendered as `X.Ys`, for the per-phase build timings.
  static String _secs(Stopwatch sw) =>
      '${(sw.elapsedMilliseconds / 1000).toStringAsFixed(1)}s';

  /// Emit a Dockerfile + .dockerignore that bake the resolved arm-gnu toolchain
  /// + sysroot into an OCI image (build context = the platform dir). Other
  /// providers don't lay out a self-contained dir to bake.
  int _emitDockerfile(CrossProfile profile, CrossTarget target) {
    if (!_canBakeImage(profile)) return ExitCode.usage.code;
    final (ctx, imageTag) = _writeImageBuildContext(profile, target);

    final tag = 'emb-cross-${profile.targetTriple}:$imageTag';
    _logger
      ..info('Wrote ${p.join(ctx.path, "Dockerfile")}')
      ..info('Build:  docker build -t $tag ${ctx.path}')
      ..info(
        'Use:    container: $tag  →  emb cross <manifest> --target '
        '<name> --build -w ${ToolchainImage.workspace}',
      );
    return ExitCode.success.code;
  }

  /// Guard: only arm-gnu lays out a self-contained platform dir (toolchain/ +
  /// sysroot/) that can be baked into an image.
  bool _canBakeImage(CrossProfile profile) {
    if (profile.providerName == 'arm-gnu') return true;
    _logger.err(
      'Toolchain images support the arm-gnu provider only '
      '(got ${profile.providerName}).',
    );
    return false;
  }

  /// Write `Dockerfile` + `.dockerignore` into the platform dir (the build
  /// context, sysroot's parent `cross-<triple>-<key>/`) and return it with the
  /// resolved sysroot key.
  (Directory, String) _writeImageBuildContext(
    CrossProfile profile,
    CrossTarget target,
  ) {
    final ctx = Directory(p.dirname(profile.targetSysroot));
    final key = sysrootKey(target);
    final dockerfile = ToolchainImage.dockerfile(
      triple: profile.targetTriple,
      sysrootKey: key,
      toolchainVersion: target.toolchainVersion,
      hostDevPackages: target.hostDevPackages,
    );
    final dockerignore = ToolchainImage.dockerignore();
    File(p.join(ctx.path, 'Dockerfile')).writeAsStringSync(dockerfile);
    File(p.join(ctx.path, '.dockerignore')).writeAsStringSync(dockerignore);
    // Content-address the image tag by the sysroot AND the baked toolset, so an
    // emitter/toolset change yields a new tag (publish re-builds instead of
    // serving a stale image). The baked paths stay keyed by sysrootKey, so a
    // consume build still hits cache.
    final imageTag = ToolchainImage.tagFor(key, dockerfile, dockerignore);
    return (ctx, imageTag);
  }

  /// Emit, then build + push the toolchain image to a registry. Registry-
  /// agnostic: the [image] prefix is free-form, auth is left to a prior
  /// `<tool> login`, and the existence probe is a plain `manifest inspect`.
  Future<int> _publishImage(
    CrossProfile profile,
    CrossTarget target, {
    required String? image,
    required List<String> tags,
    required bool force,
    required bool push,
    required String? toolOverride,
  }) async {
    if (!_canBakeImage(profile)) return ExitCode.usage.code;
    // --image presence is validated early in run(), before resolve.
    final imagePrefix = image!;

    final tool = await _resolveContainerTool(toolOverride);
    if (tool == null) {
      _logger.err(
        'No container tool found (looked for docker, podman). '
        'Install one or pass --container-tool.',
      );
      return ExitCode.unavailable.code;
    }

    final (ctx, imageTag) = _writeImageBuildContext(profile, target);
    final plan = ImagePublishPlan(
      tool: tool,
      contextDir: ctx.path,
      imagePrefix: imagePrefix,
      // Always publish (and skip-check) the content-addressed image tag
      // (sysroot + toolset) as the primary tag, so a changed manifest or
      // toolset is never masked by a moving alias; --tag values are pushed as
      // additional aliases on top.
      tags: [imageTag, ...tags.where((t) => t != imageTag)],
      push: push,
    );

    // skip-on-exists is handled before the resolve (see _publishedAlready); by
    // the time we are here the image is absent (or --force/--no-push), so build.

    if (!await _runStep('build', plan.build())) return ExitCode.software.code;
    for (final cmd in plan.pushes()) {
      if (!await _runStep('push', cmd)) return ExitCode.software.code;
    }

    _logger
      ..info(push ? 'Published ${plan.refs().join(", ")}' : 'Built (no push)')
      ..info(
        'Use:    container: ${plan.primaryRef}  →  emb cross <manifest> '
        '--target <name> --build -w ${ToolchainImage.workspace}',
      );
    return ExitCode.success.code;
  }

  /// First of [override], `docker`, `podman` that responds to `--version`.
  Future<String?> _resolveContainerTool(String? override) async {
    for (final tool in [if (override != null) override, 'docker', 'podman']) {
      if (await _hasExecutable(tool)) return tool;
    }
    return null;
  }

  /// Whether [exe] is on PATH (responds to `--version`).
  Future<bool> _hasExecutable(String exe) async {
    try {
      final r = await _runProcess(exe, ['--version']);
      return r.exitCode == 0;
    } on ProcessException {
      return false;
    }
  }

  /// Whether the content-addressed toolchain image for [target] is already
  /// published — computed from the manifest alone (sysroot key + toolset hash),
  /// so `--publish` can skip the toolchain/sysroot resolve entirely. The tag
  /// matches the one [_writeImageBuildContext] would emit post-resolve.
  Future<bool> _publishedAlready(
    CrossTarget target, {
    required String triple,
    required String image,
    required String? toolOverride,
  }) async {
    final tool = await _resolveContainerTool(toolOverride);
    if (tool == null) return false; // the full path reports the tool error
    // Use the provider's resolved triple, not `target.targetTriple ?? ''`: the
    // build tags with the resolved default (aarch64-none-linux-gnu) for a
    // manifest that omits `triple`, so probing the empty-triple tag would never
    // match and the skip-on-exists fast path would be dead.
    final imageTag = ToolchainImage.imageTag(
      triple: triple,
      sysrootKey: sysrootKey(target),
      toolchainVersion: target.toolchainVersion,
      hostDevPackages: target.hostDevPackages,
    );
    final plan = ImagePublishPlan(
      tool: tool,
      contextDir: '', // unused for the existence probe
      imagePrefix: image,
      tags: [imageTag],
    );
    if (await _refExists(
      plan,
      skopeoAvailable: await _hasExecutable('skopeo'),
    )) {
      _logger.info('${plan.primaryRef} already published — skipping resolve.');
      return true;
    }
    return false;
  }

  /// Whether the plan's primary ref already exists in the registry (the probe
  /// exits 0).
  Future<bool> _refExists(
    ImagePublishPlan plan, {
    required bool skopeoAvailable,
  }) async {
    final probe = plan.existsProbe(skopeoAvailable: skopeoAvailable);
    try {
      final r = await _runProcess(probe.exe, probe.args);
      return r.exitCode == 0;
    } on ProcessException {
      return false;
    }
  }

  /// Run one publish step. At `-v` the container tool's output streams live;
  /// otherwise it is captured and its stderr surfaced on failure.
  Future<bool> _runStep(String label, ContainerCmd cmd) async {
    _logger.info('\$ $cmd');
    final RunResult r;
    try {
      r = await _runProcess(
        cmd.exe,
        cmd.args,
        output: ProcessOutputMode.stream,
      );
    } on ProcessException catch (e) {
      _logger.err('$label failed: ${e.message}');
      return false;
    }
    if (r.exitCode != 0) {
      final err = r.stderr.trim();
      final detail = err.isEmpty ? '' : ': $err';
      _logger.err('$label failed (exit ${r.exitCode})$detail');
      return false;
    }
    return true;
  }

  /// The host tool versions this resolve ran with, for the lock's root `env`
  /// self-pins. Each is best-effort: a missing SDK/tool records null rather
  /// than failing the build.
  Future<LockEnv> _selfPins(Workspace workspace) async {
    return LockEnv(
      embVersion: packageVersion,
      engineCommit: workspace.engineCommit(),
      flutterCommit: await _gitHead(workspace.flutterDir),
      rustcVersion: await _rustcVersion(),
    );
  }

  /// The git HEAD commit of [dir], or null when it isn't a checkout / git is
  /// unavailable.
  Future<String?> _gitHead(Directory dir) async {
    if (!dir.existsSync()) return null;
    if ((await _preflight.missingTools(['git'])).isNotEmpty) return null;
    final r = await _runProcess('git', ['-C', dir.path, 'rev-parse', 'HEAD']);
    if (r.exitCode != 0) return null;
    final out = r.stdout.trim();
    return out.isEmpty ? null : out;
  }

  /// The `rustc --version` line (e.g. `rustc 1.79.0 (...)`), or null when rustc
  /// isn't installed.
  Future<String?> _rustcVersion() async {
    if ((await _preflight.missingTools(['rustc'])).isNotEmpty) return null;
    final r = await _runProcess('rustc', ['--version']);
    if (r.exitCode != 0) return null;
    final out = r.stdout.trim();
    return out.isEmpty ? null : out;
  }

  /// Reconcile `<projectRoot>/emb.lock` with the freshly [resolved] facts.
  ///
  /// Auto-creates the entry when absent (first resolve, pub-style), verifies
  /// and fails on drift when present, or rewrites it under [updateLock]. The
  /// root [env] self-pins are attached when (re)writing. Returns false only on
  /// a verification failure (the caller then exits).
  bool _syncLock({
    required String projectRoot,
    required String target,
    required LockedTarget resolved,
    required LockEnv env,
    required bool updateLock,
    required bool verify,
  }) {
    final lockFile = File(p.join(projectRoot, 'emb.lock'));
    final EmbLock? existing;
    try {
      existing = EmbLock.load(lockFile);
    } on FormatException catch (e) {
      _logger.err('emb.lock is malformed: ${e.message}');
      return false;
    }
    final had = existing?.targets[target] != null;
    final outcome = reconcileLock(
      existing: existing,
      target: target,
      resolved: resolved,
      updateLock: updateLock,
      verify: verify,
    );
    switch (outcome.action) {
      case LockAction.wrote:
        outcome.lock!.withEnv(env).save(lockFile);
        _logger.info('${had ? "Updated" : "Wrote"} emb.lock ($target).');
        return true;
      case LockAction.verified:
        // Confirm a real match; stay quiet when --no-verify skipped the check
        // (reconcileLock also reports `verified` in that case).
        if (verify) _logger.success('emb.lock verified ($target).');
        return true;
      case LockAction.drifted:
        _logger.err('emb.lock drift for "$target":');
        for (final problem in outcome.problems) {
          _logger.err('  - $problem');
        }
        _logger.err(
          'Re-run with --update-lock to accept, or --no-verify to skip.',
        );
        return false;
    }
  }

  /// Resolve [CrossTarget.launcher] to a compiler-launcher executable, or null.
  ///
  /// Warns and disables (never fails a build) when the tool is absent on
  /// `PATH`. sccache is applied to CMake only; with a Meson generator it warns
  /// that it has no effect there.
  Future<String?> _resolveLauncher(CrossTarget target) async {
    final exe = target.launcher.exe;
    if (exe == null) return null;
    if ((await _preflight.missingTools([exe])).isNotEmpty) {
      _logger.warn('launcher $exe not found on PATH; building without it');
      return null;
    }
    if (target.launcher == Launcher.sccache &&
        target.generator == CrossGenerator.meson) {
      _logger.warn(
        'launcher sccache applies to CMake only; the Meson build will not '
        'use it',
      );
    }
    return exe;
  }
}
