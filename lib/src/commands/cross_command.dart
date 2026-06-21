import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:emb_cli/src/aot/aot_builder.dart';
import 'package:emb_cli/src/bundle/bundle_builder.dart';
import 'package:emb_cli/src/bundle/bundle_pipeline.dart';
import 'package:emb_cli/src/cross/cross_arch.dart';
import 'package:emb_cli/src/cross/cross_builder.dart';
import 'package:emb_cli/src/cross/cross_keys.dart';
import 'package:emb_cli/src/cross/cross_profile.dart';
import 'package:emb_cli/src/cross/cross_project.dart';
import 'package:emb_cli/src/cross/cross_provider.dart';
import 'package:emb_cli/src/cross/cross_target.dart';
import 'package:emb_cli/src/cross/deb_packager.dart';
import 'package:emb_cli/src/cross/deployer.dart';
import 'package:emb_cli/src/cross/dockerfile_emitter.dart';
import 'package:emb_cli/src/cross/emb_lock.dart';
import 'package:emb_cli/src/cross/image_publisher.dart';
import 'package:emb_cli/src/cross/local_cross_provider.dart';
import 'package:emb_cli/src/cross/overlay_builder.dart';
import 'package:emb_cli/src/cross/process_runner.dart';
import 'package:emb_cli/src/cross/runnable_bundle.dart';
import 'package:emb_cli/src/engine/engine_artifacts.dart';
import 'package:emb_cli/src/host/host_info.dart';
import 'package:emb_cli/src/host/install_hint.dart';
import 'package:emb_cli/src/manifest/manifest_loader.dart';
import 'package:emb_cli/src/pkg/host_provisioner.dart';
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
    ProcessRunner processRunner = defaultProcessRunner,
  }) : _logger = logger,
       _host = host,
       _project = CrossProjectResolver(loader),
       _aotFactory = aotFactory ?? ((ws, h) => AotBuilder(ws, host: h)),
       _bundleFactory = bundleFactory ?? BundleBuilder.new,
       _engineFactory = engineFactory ?? EngineArtifacts.new,
       _runProcess = processRunner {
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
        help: 'After --deploy, run the bundle on the target over SSH.',
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
  final AotBuilder Function(Workspace ws, HostInfo host) _aotFactory;
  final BundleBuilder Function(Workspace ws) _bundleFactory;
  final EngineArtifacts Function(Workspace ws) _engineFactory;
  final ProcessRunner _runProcess;

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

    // --dry-run: report the plan without any download / mount / ssh side
    // effects, so every target validates on any host.
    if (args['dry-run'] == true) {
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
        image: publishImage!,
        toolOverride: args['container-tool'] as String?,
      )) {
        return ExitCode.success.code;
      }
    }

    // Provider-declared preflight (tar/xz/rsync for arm-gnu, etc.).
    final missing = await _missingTools(provider.preflightTools);
    if (missing.isNotEmpty) {
      if (args['install-deps'] == true) {
        if (!await _installPreflight(host, provider.name, missing)) {
          return ExitCode.unavailable.code;
        }
      } else {
        _logger.err(
          'Missing host tools for ${provider.name}: ${missing.join(", ")}',
        );
        await _logInstallHint(host, missing);
        return ExitCode.unavailable.code;
      }
    }

    final progress = _logger.progress(
      'Resolving ${provider.name} cross profile',
    );
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
      final projectRoot = FileSystemEntity.isDirectorySync(inputPath)
          ? inputPath
          : p.dirname(inputPath);
      if (!_syncLock(
        projectRoot: projectRoot,
        target: effectiveTarget,
        resolved: resolved,
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

    // --publish: emit, then build + push the toolchain image to a registry.
    if (args['publish'] == true) {
      return _publishImage(
        profile,
        target,
        image: args['image'] as String?,
        tags: args['tag'] as List<String>,
        force: args['force'] == true,
        push: args['push'] == true,
        toolOverride: args['container-tool'] as String?,
      );
    }

    if (args['prepare'] == true && target.augment.isNotEmpty) {
      final overlay = OverlayBuilder(workspace, profile);
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
      return _build(
        profile,
        target,
        workspace,
        inputPath,
        host: host,
        deb: args['deb'] == true,
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

    // --backend filters the matrix (validated in run()); merge shared
    // cross.defines into each backend (a backend define wins on a clash).
    final backends = {
      for (final e in target.backends.entries)
        if (selectedBackends.isEmpty || selectedBackends.contains(e.key))
          e.key: {...target.defines, ...e.value},
    };

    // Stage any augment libraries the sysroot doesn't already satisfy (e.g.
    // libdisplay-info >= 0.2.0) into the sysroot before configuring, so the
    // embedder's pkg-config probes resolve them. Native builds use the host's
    // system libraries instead (install via the manifest deps / emb deps).
    if (!native && target.augment.isNotEmpty) {
      final sw = Stopwatch()..start();
      final overlay = OverlayBuilder(workspace, profile);
      try {
        await overlay.build(
          target.augment,
          stageInto: Directory(profile.targetSysroot),
        );
      } on OverlayBuildException catch (e) {
        _logger.err('augment: ${e.message}');
        return ExitCode.software.code;
      } finally {
        overlay.close();
      }
      _logger.info(
        '  augment       : ${target.augment.map((a) => a.pkg).join(", ")} '
        'staged (${_secs(sw)})',
      );
    }

    final buildRoot = workspace.ensurePlatformDir(
      'cross-build-${profile.targetTriple}-${buildKey(target)}',
    );
    // Native keeps the host compiler env; cross neutralizes it.
    final builder = CrossBuilder(
      profile,
      neutralizeHostEnv: !native,
      hostTools: hostTools,
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
    if (appPath != null) {
      final rc = await _runnable(
        profile,
        target,
        buildRoot,
        built,
        host: host,
        workspace: workspace,
        appPath: appPath,
        mode: mode,
        tar: tar,
        deployHost: deployHost,
        deployDir: deployDir,
        run: run,
      );
      if (rc != ExitCode.success.code) return rc;
    }

    if (deb) {
      return _packageDebs(profile, target, buildRoot, built, defaultName);
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
    required HostInfo host,
    required Workspace workspace,
    required String appPath,
    required String mode,
    required bool tar,
    String? deployHost,
    String deployDir = 'ivi-homescreen',
    bool run = false,
  }) async {
    final arch = EngineArtifacts.engineArch(archOfTriple(profile.targetTriple));

    // Build the app bundle once (engine fetch + AOT + assemble).
    final appBundle = Directory(
      p.join(buildRoot.path, 'app-bundle-$mode-$arch'),
    );
    final progress = _logger.progress('Building app bundle ($mode/$arch)');
    final res = await buildAndAssemble(
      workspace: workspace,
      aot: _aotFactory(workspace, host),
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
    final deployer = Deployer();
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

    final progress = _logger.progress('Deploying → $host:$destDir');
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
  ) async {
    final spec = target.package ?? const PackageSpec();
    final arch = debianArch(profile.targetTriple);
    final baseName = spec.name ?? defaultName;
    final outDir = Directory(p.join(buildRoot.path, 'dist'));
    // The resolver's downloaded `.deb`s sit beside the sysroot, in `debs/`.
    final debDirs = [
      Directory(p.join(p.dirname(profile.targetSysroot), 'debs')),
    ];
    final packager = DebPackager(readelf: _readelfFor(profile));

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
        );
        _logger.info('  ${r.backend ?? ""}: packaged → ${out.path}');
      } on DebPackageException catch (e) {
        _logger.err('  ${r.backend ?? ""}: ${e.message}');
        return ExitCode.software.code;
      }
    }
    return ExitCode.success.code;
  }

  /// The binary to package: [bin] resolved under [buildDir], else the first ELF
  /// executable found there.
  File? _artifactFor(String buildDir, String? bin) {
    if (bin != null) {
      final f = File(p.join(buildDir, bin));
      return f.existsSync() ? f : null;
    }
    for (final e in Directory(buildDir).listSync(recursive: true)) {
      if (e is! File) continue;
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
    final missing = await _missingTools(provider.preflightTools);
    _logger
      ..info(styleBold.wrap('Cross plan (${provider.name})'))
      ..info('  triple        : ${target.triple ?? "(provider default)"}')
      ..info('  cpu flags     : ${target.cpuFlags.join(" ")}')
      ..info('  host          : ${host.os.name}/${host.machineArch}')
      ..info(
        '  preflight     : '
        '${missing.isEmpty ? "ok" : "MISSING ${missing.join(", ")}"}',
      );
    if (missing.isNotEmpty) await _logInstallHint(host, missing);
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
    required String image,
    required String? toolOverride,
  }) async {
    final tool = await _resolveContainerTool(toolOverride);
    if (tool == null) return false; // the full path reports the tool error
    final imageTag = ToolchainImage.imageTag(
      triple: target.targetTriple ?? '',
      sysrootKey: sysrootKey(target),
      toolchainVersion: target.toolchainVersion,
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

  /// Run one publish step, streaming nothing but surfacing stderr on failure.
  Future<bool> _runStep(String label, ContainerCmd cmd) async {
    _logger.info('\$ $cmd');
    final ProcessResult r;
    try {
      r = await _runProcess(cmd.exe, cmd.args);
    } on ProcessException catch (e) {
      _logger.err('$label failed: ${e.message}');
      return false;
    }
    if (r.exitCode != 0) {
      final err = (r.stderr as String?)?.trim() ?? '';
      final detail = err.isEmpty ? '' : ': $err';
      _logger.err('$label failed (exit ${r.exitCode})$detail');
      return false;
    }
    return true;
  }

  /// Reconcile `<projectRoot>/emb.lock` with the freshly [resolved] facts.
  ///
  /// Auto-creates the entry when absent (first resolve, pub-style), verifies
  /// and fails on drift when present, or rewrites it under [updateLock].
  /// Returns false only on a verification failure (the caller then exits).
  bool _syncLock({
    required String projectRoot,
    required String target,
    required LockedTarget resolved,
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
        outcome.lock!.save(lockFile);
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

  Future<List<String>> _missingTools(List<String> tools) async {
    final missing = <String>[];
    for (final t in tools) {
      final r = await Process.run('which', [t]);
      if (r.exitCode != 0) missing.add(t);
    }
    return missing;
  }

  /// Install the missing preflight [tools] via [HostProvisioner] (opt-in, with
  /// `--install-deps`). Returns true only when the tools are present after.
  /// Falls back to the manual hint when no backend is reachable.
  Future<bool> _installPreflight(
    HostInfo host,
    String providerName,
    List<String> tools,
  ) async {
    HostProvisioner? provisioner;
    try {
      provisioner = HostProvisioner.forHost(host);
      // ignore: avoid_catching_errors
    } on UnsupportedError {
      provisioner = null;
    }
    if (provisioner == null || !await provisioner.isAvailable()) {
      await provisioner?.dispose();
      _logger.err(
        'Cannot auto-install host tools (no package backend). Install '
        'manually:',
      );
      await _logInstallHint(host, tools);
      return false;
    }

    final progress = _logger.progress(
      'Installing host tools for $providerName: ${tools.join(", ")}',
    );
    try {
      final result = await provisioner.install(
        tools.toSet(),
        onProgress: (p) => progress.update(p.label),
      );
      if (!result.success) {
        progress.fail(
          result.message ?? 'install failed: ${result.failed.join(", ")}',
        );
        return false;
      }
      progress.complete('Installed: ${result.installed.join(", ")}');
    } on Exception catch (e) {
      progress.fail('install failed: $e');
      return false;
    } finally {
      await provisioner.dispose();
    }

    // The backend reported success; confirm the binaries are actually on PATH.
    final stillMissing = await _missingTools(tools);
    if (stillMissing.isNotEmpty) {
      _logger.err('Still missing after install: ${stillMissing.join(", ")}');
      return false;
    }
    return true;
  }

  /// Log how to install the missing preflight [tools].
  ///
  /// Routes through the existing [HostProvisioner] first — it resolves real
  /// package names from the running backend (PackageKit `WhatProvides`, brew,
  /// …), so there is no second distro→package map to drift. Only when no
  /// backend is reachable (no daemon / native bridge, or a platform backend
  /// not compiled into this build) does it fall back to [staticInstallHint].
  Future<void> _logInstallHint(HostInfo host, List<String> tools) async {
    HostProvisioner? provisioner;
    try {
      provisioner = HostProvisioner.forHost(host);
      // forHost throws UnsupportedError when the platform backend isn't
      // compiled in (default macOS/Windows) — fall back to the static hint.
      // ignore: avoid_catching_errors
    } on UnsupportedError {
      provisioner = null;
    }
    if (provisioner != null) {
      try {
        if (await provisioner.isAvailable()) {
          final plan = await provisioner.simulate(tools.toSet());
          final pkgs = [...plan.toInstall, ...plan.unresolved];
          if (pkgs.isNotEmpty) {
            _logger.info('Install via ${provisioner.name}: ${pkgs.join(", ")}');
            return;
          }
        }
      } on Exception {
        // Any provisioner error → fall back to the static hint below.
      } finally {
        await provisioner.dispose();
      }
    }
    final hint = staticInstallHint(host, tools);
    if (hint != null) _logger.info('Install with: $hint');
  }
}
