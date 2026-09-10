import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:crypto/crypto.dart';
import 'package:emb_cli/src/aot/aot_builder.dart';
import 'package:emb_cli/src/bundle/bundle_builder.dart';
import 'package:emb_cli/src/bundle/bundle_pipeline.dart';
import 'package:emb_cli/src/cache/cache_dir.dart';
import 'package:emb_cli/src/cross/bundle_audit.dart';
import 'package:emb_cli/src/cross/cargo_env.dart';
import 'package:emb_cli/src/cross/cargo_vendor.dart';
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
import 'package:emb_cli/src/cross/elf_check.dart';
import 'package:emb_cli/src/cross/emb_lock.dart';
import 'package:emb_cli/src/cross/flatpak_packager.dart';
import 'package:emb_cli/src/cross/flatpak_vendor.dart';
import 'package:emb_cli/src/cross/image_publisher.dart';
import 'package:emb_cli/src/cross/ipk_packager.dart';
import 'package:emb_cli/src/cross/local_cross_provider.dart';
import 'package:emb_cli/src/cross/lock_sync.dart';
import 'package:emb_cli/src/cross/module_stager.dart';
import 'package:emb_cli/src/cross/offline_enforcement.dart';
import 'package:emb_cli/src/cross/overlay_builder.dart';
import 'package:emb_cli/src/cross/package_files.dart';
import 'package:emb_cli/src/cross/process_runner.dart';
import 'package:emb_cli/src/cross/rpm_packager.dart';
import 'package:emb_cli/src/cross/runnable_bundle.dart';
import 'package:emb_cli/src/cross/tarball_packager.dart';
import 'package:emb_cli/src/engine/engine_artifacts.dart';
import 'package:emb_cli/src/host/host_info.dart';
import 'package:emb_cli/src/host/interactivity.dart';
import 'package:emb_cli/src/host/preflight.dart';
import 'package:emb_cli/src/json_output.dart';
import 'package:emb_cli/src/manifest/manifest_loader.dart';
import 'package:emb_cli/src/step_reporter.dart';
import 'package:emb_cli/src/verbosity.dart';
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
/// Bundle-relative rpath, applied to every cross build unless a manifest
/// overrides it.
///
/// A bundle stages the engine, the app image, the embedder's shared library and
/// any Dart code assets into `lib/` beside the executable — a fixed layout (see
/// `auditBundleLib`, which reads exactly that directory). Without this the
/// binary carries absolute build-host paths and dies on the device with
/// "cannot open shared object file"; the build host's checkout is not there.
///
/// `BUILD_WITH_INSTALL_RPATH` because a bundle is assembled straight out of the
/// build tree and never `cmake --install`ed, so the build-tree rpath ships.
/// Both entries are needed: the executable sits at the bundle root and reaches
/// libraries via `$ORIGIN/lib`, while a library already inside `lib/` reaches
/// its siblings via `$ORIGIN`.
///
/// This is exact for the layouts that keep the tree together — the runnable
/// bundle (and so an rsync `--deploy`) and the flatpak, which copies the bundle
/// intact to `/app/<appId>`. It does *not* describe the distro packages, which
/// split the binary to `install_dir` (`/usr/bin`) and the libraries to
/// `/usr/lib/<multiarch>`; there the entries simply resolve to nothing and the
/// loader finds the libraries on its default search path, so the rpath is inert
/// rather than wrong. A board that needs something else states its own
/// `CMAKE_INSTALL_RPATH`, which wins (see [mergeBackendDefines]).
const Map<String, String> rpathDefines = {
  'CMAKE_BUILD_WITH_INSTALL_RPATH': 'ON',
  'CMAKE_INSTALL_RPATH': r'$ORIGIN/lib:$ORIGIN',
};

/// One backend's cache entries: the [rpathDefines] defaults, under the target's
/// shared `cross.defines`, under the backend's own entry. Later wins, so a
/// manifest that states an rpath of its own keeps it.
Map<String, String> mergeBackendDefines(
  Map<String, String> targetDefines,
  Map<String, String> backendDefines,
) => {...rpathDefines, ...targetDefines, ...backendDefines};

/// Content-based fingerprint of a source tree: sorted relative paths with a
/// SHA-256 digest of each file's bytes, hashed into a short hex string.
/// Hidden entries (`.git`, `.dart_tool`, etc.) are excluded.
///
/// Uses file content rather than mtime so that `git checkout`, `cp -a`, and
/// filesystems with coarse timestamp granularity (HFS+, FAT32) don't produce
/// false cache hits.
///
/// Symlinks are followed — a source tree that links to vendored or shared
/// sources builds from the link target, so the fingerprint has to see it too
/// or an edit behind a link reads as "unchanged" and the build is wrongly
/// skipped. Directories are tracked by their resolved path, so a link that
/// points at an ancestor is visited once instead of recursing forever.
String sourceFingerprint(Directory dir) {
  final parts = <String>[];
  final visited = <String>{};
  final queue = <(Directory, String)>[(dir, '')];

  while (queue.isNotEmpty) {
    final (current, prefix) = queue.removeLast();
    final String resolved;
    final List<FileSystemEntity> entries;
    try {
      resolved = current.resolveSymbolicLinksSync();
      if (!visited.add(resolved)) continue; // already walked (link cycle)
      // followLinks: false, then resolve each entry's own type below — a
      // Link is otherwise reported as a Link and dropped.
      entries = current.listSync(followLinks: false);
    } on FileSystemException {
      continue; // unreadable dir or dangling link
    }
    for (final e in entries) {
      final name = p.basename(e.path);
      if (name.startsWith('.')) continue;
      final rel = prefix.isEmpty ? name : p.join(prefix, name);
      // typeSync follows links, so a linked file/dir resolves to its target.
      final type = FileSystemEntity.typeSync(e.path);
      if (type == FileSystemEntityType.directory) {
        queue.add((Directory(e.path), rel));
      } else if (type == FileSystemEntityType.file) {
        try {
          parts.add('$rel:${sha256.convert(File(e.path).readAsBytesSync())}');
        } on FileSystemException {
          parts.add('$rel:?');
        }
      } else {
        // A dangling link, socket, or fifo: record its presence so adding or
        // removing one still moves the fingerprint.
        parts.add('$rel:?');
      }
    }
  }
  parts.sort();
  return contentHash(parts);
}

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
    Map<String, String>? environment,
  }) : _logger = logger,
       _environment = environment ?? Platform.environment,
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
      ..addMultiOption(
        'define',
        abbr: 'D',
        splitCommas: false,
        valueHelp: 'KEY=VALUE',
        help:
            'Override a build-system -D define (repeatable), for either a '
            'CMake or a Meson embedder. Always wins over the manifest: '
            'cross.defines, any backends entry, and anything an extends '
            'chain merged in. Embedder configure only (augment and module '
            'builds keep their own defines).',
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
            'Send the build to a board. <user@host> deploys over SSH '
            '(port/opts reused from cross.sysroot when device-sourced); '
            '"adb" or '
            '"adb:<serial>" deploys over adb, as does any value when '
            'cross.sysroot.transport is adb. With --app: push each runnable '
            'bundle. With --deb: scp each .deb and apt-get install it '
            '(SSH only — needs apt on the board).',
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
            'the --deploy target over its transport (ssh/adb).',
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
        'fetch-only',
        help:
            'Resolve and materialize the toolchain + sysroot closure (and pin '
            'emb.lock), then stop before configuring or building. The '
            'acquisition step to run once while online.',
        negatable: false,
      )
      ..addFlag(
        'offline',
        help:
            'Deny all network access: reuse already-cached toolchain/sysroot '
            'inputs and fail on a miss (run --fetch-only online first). Also '
            'builds cargo modules with CARGO_NET_OFFLINE.',
        negatable: false,
      )
      ..addFlag(
        'offline-strict',
        help:
            'Like --offline, but also run build subprocesses inside a network '
            'namespace and refuse to build when that isolation is unavailable '
            '(rather than degrading to input-level denial only).',
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
        'obfuscate',
        help:
            'Rename every identifier in the app AOT snapshot. Defaults to on '
            'for release and off for profile. Whenever on, the obfuscation '
            'map is written next to the image — keep it, or stack traces from '
            'that build can never be symbolized.',
      )
      ..addFlag(
        'strip',
        defaultsTo: true,
        help:
            'Strip the symbol table from the app AOT snapshot. Pass '
            '--no-strip to keep it for perf/gdb.',
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
        'interactive',
        help:
            'Allow the system package manager to prompt for authorization '
            'when --install-deps is used. On by default; pass '
            '--no-interactive for unattended runs.',
        defaultsTo: null,
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
  final Map<String, String> _environment;
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
  /// to [runProcess] (defaulting to the verbosity-aware [_runProcess] so AOT
  /// output streams at `-v`). Offline builds pass a runner that injects the
  /// store `PUB_CACHE` and (under strict) the network namespace.
  AotBuilder _makeAot(
    Workspace ws,
    HostInfo host, {
    ProcessRunner? runProcess,
  }) =>
      _aotFactoryInjected?.call(ws, host) ??
      AotBuilder(ws, host: host, runProcess: runProcess ?? _runProcess);

  /// Progress reporter that draws spinners normally but plain banners at `-v`+,
  /// where a spinner would garble streamed toolchain output. Read fresh so it
  /// reflects the verbosity resolved after construction.
  StepReporter get _steps => StepReporter(_logger);

  /// Host-tool preflight (missing-tool probe, install hints, opt-in install),
  /// shared with `emb doctor --target`.
  /// The offline denial level for this run, and whether build subprocesses are
  /// wrapped in a network namespace — resolved in [run] once the host's
  /// isolation capability is known, then read by the module build.
  OfflineMode _offlineMode = OfflineMode.off;
  bool _offlineWrap = false;

  late final Preflight _preflight = Preflight(_logger);
  late final LockSync _lockSync = LockSync(
    logger: _logger,
    runProcess: _runProcess,
    preflight: _preflight,
  );

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
    // Native uses the shared fields (backends / defines / package); the
    // cross-only fields (image_url, toolchain, cpu_flags) don't apply.
    final selection = project.selectTarget(args['target'] as String?);
    if (selection == null) {
      _logger.err(
        'Unknown target "${args['target']}". '
        'Available: ${project.targets.keys.join(", ")}',
      );
      return ExitCode.usage.code;
    }
    final effectiveTarget = selection.name;
    final isNative = selection.isNative;

    // An `--app` may carry its own `.emb/` layer, merged over the project's.
    // The project owns the board profile its apps share; this is where one app
    // states what only it needs — a `-dev` package its Dart build hooks link
    // against, or a source-built dependency the embedder links — without every
    // consumer of that board carrying it. A native build reads the app's
    // shared `cross:` block, the same one the project's native build uses:
    // `sysroot` has nothing to add to on the host, but `defines` and `augment`
    // apply to a host build exactly as they do to a cross one.
    final appDirArg = args['app'] as String?;
    final selected = appDirArg == null
        ? selection.cross
        : _project.applyAppLayer(
            cross: selection.cross,
            appDir: appDirArg,
            targetName: effectiveTarget,
            native: isNative,
          );
    final appLayerSource = appDirArg == null
        ? null
        : _project.appLayerSourcePath(
            appDir: appDirArg,
            targetName: effectiveTarget,
            native: isNative,
          );

    // --define KEY=VALUE overrides: parsed up front (usage error before any
    // download), then baked into the target itself so buildKey, the backend
    // matrix, the no-backend build, and --dry-run all see the final values.
    final Map<String, String> cliDefines;
    try {
      cliDefines = CrossTarget.parseDefineOverrides(
        args['define'] as List<String>,
      );
    } on FormatException catch (e) {
      _logger.err(e.message);
      return ExitCode.usage.code;
    }

    final CrossTarget target;
    try {
      target = CrossTarget.fromMap(selected)
          .withResolvedPatches(appLayerSource ?? selection.sourcePath)
          .withDefineOverrides(cliDefines);
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
    // --offline-strict implies --offline; it additionally requires a network
    // namespace around build subprocesses (see the build dispatch below).
    _offlineMode = args['offline-strict'] == true
        ? OfflineMode.strict
        : args['offline'] == true
        ? OfflineMode.deny
        : OfflineMode.off;
    final offline = _offlineMode != OfflineMode.off;
    final provider = isNative
        ? LocalCrossProvider(host)
        : CrossProvider.forTarget(
            target,
            workspace: workspace,
            host: host,
            offline: offline,
          );

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
      // The image is only half of what a consuming build needs. It carries no
      // toolchain -- its dockerignore is `*` and it copies nothing -- so the
      // sysroot base and toolchain reach a build through the shared cache
      // instead. Skipping on the image alone leaves that cache empty, and
      // leaves it empty permanently: the push that would fill it lives after
      // the resolve this skip is avoiding, so every consuming build re-resolves
      // from scratch forever while the image keeps looking up to date.
      final fastPathCache = CrossCache.fromEnv(
        environment: Platform.environment,
        run: _runProcess,
        logger: _logger,
      );
      final fastPathSelectors = provider.cacheSelectors();
      final cacheReady =
          fastPathCache == null ||
          fastPathSelectors.isEmpty ||
          await fastPathCache.hasAll(fastPathSelectors);

      if (cacheReady &&
          await _publishedAlready(
            target,
            triple: provider.triple,
            image: publishImage!,
            toolOverride: args['container-tool'] as String?,
            requestedTags: args['tag'] as List<String>,
          )) {
        return ExitCode.success.code;
      }
      if (!cacheReady) {
        _logger.info(
          'shared cache is missing artifacts a build would need — '
          'resolving so they can be published.',
        );
      }
    }

    // Provider-declared preflight (tar/xz/rsync for arm-gnu, etc.).
    final missing = await _preflight.missingTools(provider.preflightTools);
    if (missing.isNotEmpty) {
      if (args['install-deps'] == true) {
        final interactivity = Interactivity.resolve(
          explicit: args.wasParsed('interactive')
              ? args['interactive'] as bool
              : null,
          environment: _environment,
        );
        _logger.detail('interactivity: ${interactivity.describe()}');
        if (!await _preflight.install(
          host,
          provider.name,
          missing,
          interactive: interactivity.interactive,
        )) {
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
      if (!_lockSync.sync(
        projectRoot: projectRoot,
        target: lockKey(
          inputPath: inputPath,
          isDirectory: isDir,
          target: effectiveTarget,
        ),
        resolved: resolved,
        env: await _lockSync.selfPins(workspace),
        updateLock: args['update-lock'] == true,
        verify: args['no-verify'] != true,
      )) {
        return ExitCode.software.code;
      }
    }

    // --fetch-only: the closure (toolchain + sysroot + apt -dev set) is now
    // materialized in the store and pinned in emb.lock. Vendor cargo modules
    // too, then stop before any build so this can run online, after which the
    // build runs with --offline.
    if (args['fetch-only'] == true) {
      if (hasCargoModules(target)) {
        if ((await _preflight.missingTools(['cargo'])).isNotEmpty) {
          _logger.err('cargo not found on PATH — cannot vendor cargo modules.');
          await _preflight.logInstallHint(host, ['cargo']);
          return ExitCode.unavailable.code;
        }
        final manifestDir =
            FileSystemEntity.typeSync(inputPath) == FileSystemEntityType.file
            ? File(inputPath).parent
            : Directory(inputPath);
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
      _logger.success('Fetched cross closure for $effectiveTarget.');
      return ExitCode.success.code;
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

    // Resolve offline enforcement and the embedder source directory once,
    // shared by both --prepare and --build.
    final doPrepare = args['prepare'] == true;
    final doBuild = args['build'] == true;

    // Validate flag combinations before any build work: --prepare now compiles
    // the embedder, so a usage error caught after it would cost a full build.
    if (doBuild && args['flatpak'] == true && args['app'] == null) {
      _logger.err('--flatpak needs --app (a flatpak bundles the whole app).');
      return ExitCode.usage.code;
    }
    if (doPrepare || doBuild) {
      final enforcement = await resolveOfflineEnforcement(
        _offlineMode,
        _runProcess,
      );
      final fatal = enforcement.fatal;
      if (fatal != null) {
        _logger.err(fatal);
        return ExitCode.unavailable.code;
      }
      final warning = enforcement.warning;
      if (warning != null) _logger.warn(warning);
      _offlineWrap = enforcement.wrap;
    }

    // Host-side `-dev` packages the manifest declares (host_dev_packages).
    // These feed a `host: true` augment — a codegen tool emb compiles with the
    // host toolchain — so they must be on the build machine, not the sysroot.
    // The Dockerfile emit bakes them into the cross image; a build running
    // straight on the host has to install them itself, or the host tool's
    // configure fails on a missing pkg-config module minutes into the build.
    if ((doPrepare || doBuild) && target.hostDevPackages.isNotEmpty) {
      final code = await _ensureHostDevPackages(
        host,
        target,
        installDeps: args['install-deps'] == true,
        interactiveOverride: args.wasParsed('interactive')
            ? args['interactive'] as bool
            : null,
      );
      if (code != null) return code;
    }

    final source =
        FileSystemEntity.typeSync(inputPath) == FileSystemEntityType.file
        ? File(inputPath).parent
        : Directory(inputPath);

    _EmbedderResult? preparedEmbedder;
    if (doPrepare) {
      preparedEmbedder = await _buildEmbedder(
        profile,
        target,
        workspace,
        source,
        launcher: launcher,
        hostTools: target.hostTools || args['host-tools'] == true,
        selectedBackends: selectedBackends,
      );
      if (preparedEmbedder == null) return ExitCode.software.code;
    }

    if (doBuild) {
      return _build(
        profile,
        target,
        workspace,
        source,
        launcher: launcher,
        preparedEmbedder: preparedEmbedder,
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
        obfuscate: args.wasParsed('obfuscate')
            ? args['obfuscate'] as bool
            : target.aotObfuscate,
        strip: args.wasParsed('strip')
            ? args['strip'] as bool
            : target.aotStrip ?? true,
        tar: args['tar'] == true,
        deployHost: args['deploy'] as String?,
        deployDir: args['deploy-dir'] as String,
        run: args['run'] == true,
        hostTools: target.hostTools || args['host-tools'] == true,
      );
    }
    return ExitCode.success.code;
  }

  /// Ensure the manifest's `host_dev_packages` are installed on the build
  /// machine, returning an exit code to stop on, or null to continue.
  ///
  /// The backend answers by package name (a `-dev` package ships no
  /// executable, so `which` cannot see it). A name the backend does not
  /// recognize counts as missing, so a host whose distro spells it differently
  /// stops here naming the package it wants — which beats failing minutes
  /// later inside the host tool's configure. Only when no backend is reachable
  /// at all does this continue, since then nothing can be verified either way.
  Future<int?> _ensureHostDevPackages(
    HostInfo host,
    CrossTarget target, {
    required bool installDeps,
    required bool? interactiveOverride,
  }) async {
    final pkgs = target.hostDevPackages;
    final status = await _preflight.missingPackages(host, pkgs);
    if (status == null) {
      _logger.detail(
        '  host dev pkgs : cannot verify ${pkgs.join(", ")} '
        '(no package backend) — assuming present',
      );
      return null;
    }
    // Names this host's backend has never heard of are almost always the same
    // package under another distro's spelling (libpugixml-dev vs
    // pugixml-devel). Say so and carry on rather than blocking a build we
    // cannot actually prove is broken.
    if (status.unresolved.isNotEmpty) {
      _logger.warn(
        "host dev packages unknown to this host's package backend: "
        '${status.unresolved.join(", ")} — these are the names the cross image '
        'bakes; install the local equivalents if the build fails',
      );
    }
    final missing = status.missing;
    if (missing.isEmpty) {
      _logger.detail('  host dev pkgs : ${pkgs.join(", ")} ok');
      return null;
    }
    if (!installDeps) {
      _logger.err(
        'Missing host dev packages: ${missing.join(", ")}\n'
        'These are build-machine deps of a host: true augment. Re-run with '
        '--install-deps, or install them yourself:',
      );
      await _preflight.logInstallHint(host, missing);
      return ExitCode.unavailable.code;
    }
    final interactivity = Interactivity.resolve(
      explicit: interactiveOverride,
      environment: _environment,
    );
    final ok = await _preflight.install(
      host,
      name,
      missing,
      interactive: interactivity.interactive,
      what: 'host dev packages',
      verifyOnPath: false,
    );
    return ok ? null : ExitCode.unavailable.code;
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

  /// Build augment libraries and the embedder, returning everything the
  /// downstream app-bundle / packaging steps need. When [skipIfBuilt] is true
  /// and every backend already has an embedder binary in its build dir, the
  /// cmake/meson step is skipped — this is the fast path when `--prepare` ran
  /// earlier.
  ///
  /// Returns null on any build failure (error is logged).
  Future<_EmbedderResult?> _buildEmbedder(
    CrossProfile profile,
    CrossTarget target,
    Workspace workspace,
    Directory source, {
    required String? launcher,
    required bool hostTools,
    List<String> selectedBackends = const [],
    bool skipIfBuilt = false,
  }) async {
    final native = profile.providerName == 'local';

    final backends = {
      for (final e in target.backends.entries)
        if (selectedBackends.isEmpty || selectedBackends.contains(e.key))
          e.key: mergeBackendDefines(target.defines, e.value),
    };

    var hostToolBins = const <String>[];
    OverlayPaths? overlayPaths;
    final augments = target.gatedAugments();
    for (final a in target.skippedAugments()) {
      _logger.detail(
        '  augment       : ${a.pkg} skipped (requires_define: '
        '${a.requiresDefine})',
      );
    }
    if (augments.isNotEmpty) {
      final sw = Stopwatch()..start();
      final overlay = OverlayBuilder(
        workspace,
        profile,
        runProcess: _runProcess,
        launcher: launcher,
      );
      try {
        overlayPaths = await overlay.build(
          augments,
          stageInto: native ? null : Directory(profile.targetSysroot),
        );
        hostToolBins = overlayPaths.binDirs;
      } on OverlayBuildException catch (e) {
        _logger.err('augment: ${e.message}');
        return null;
      } finally {
        overlay.close();
      }
      _logger.info(
        '  augment       : ${augments.map((a) => a.pkg).join(", ")} '
        'built (${_secs(sw)})',
      );
    }

    final buildRoot = workspace.ensurePlatformDir(
      'cross-build-${profile.targetTriple}-${buildKey(target)}',
    );

    final builder = CrossBuilder(
      profile,
      runProcess: _offlineWrap ? netnsRunner(_runProcess) : _runProcess,
      neutralizeHostEnv: !native,
      hostTools: hostTools,
      hostToolBins: hostToolBins,
      launcher: launcher,
      ccacheBaseDir: workspace.root.path,
      overlay: overlayPaths,
    );

    // Fingerprint the embedder source tree so a subsequent --build detects
    // edits. Computed unconditionally: the skip check reads it, and a
    // successful build writes it.
    final fingerprint = _sourceFingerprint(source);
    final stampFile = File(p.join(buildRoot.path, '.emb-source-stamp'));

    // When the caller says skip-if-built, check that (a) the source hasn't
    // changed since the last build and (b) every backend has an embedder
    // binary. The build root name encodes buildKey(target), so a config
    // change yields a new dir and the check naturally misses.
    if (skipIfBuilt) {
      final stampMatch =
          stampFile.existsSync() &&
          stampFile.readAsStringSync().trim() == fingerprint;
      if (stampMatch) {
        final existing = <CrossBuildResult>[];
        var allPresent = true;
        if (backends.isEmpty) {
          final dir = Directory(p.join(buildRoot.path, 'build'));
          if (dir.existsSync() &&
              _artifactFor(dir.path, target.package?.bin) != null) {
            existing.add(CrossBuildResult(success: true, buildDir: dir.path));
          } else {
            allPresent = false;
          }
        } else {
          for (final name in backends.keys) {
            final dir = Directory(p.join(buildRoot.path, 'build-$name'));
            if (dir.existsSync() &&
                _artifactFor(dir.path, target.package?.bin) != null) {
              existing.add(
                CrossBuildResult(
                  success: true,
                  buildDir: dir.path,
                  backend: name,
                ),
              );
            } else {
              allPresent = false;
              break;
            }
          }
        }
        if (allPresent && existing.isNotEmpty) {
          _logger.info('  embedder      : up-to-date (skipped)');
          return _EmbedderResult(
            results: existing,
            buildRoot: buildRoot,
            builder: builder,
            overlayPaths: overlayPaths,
          );
        }
      }
    }

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
    if (!results.every((r) => r.success)) return null;

    stampFile.writeAsStringSync(fingerprint);

    return _EmbedderResult(
      results: results,
      buildRoot: buildRoot,
      builder: builder,
      overlayPaths: overlayPaths,
    );
  }

  /// Build the app bundle and assemble runnable output. Delegates augment +
  /// embedder compilation to [_buildEmbedder] (which skips the cmake/meson
  /// step when a prior `--prepare` already produced the binary), then proceeds
  /// to Flutter app compilation, packaging, and deploy.
  ///
  /// When [preparedEmbedder] is supplied (from a `--prepare` in the same
  /// invocation) the embedder step is skipped entirely.
  Future<int> _build(
    CrossProfile profile,
    CrossTarget target,
    Workspace workspace,
    Directory source, {
    required String? launcher,
    required HostInfo host,
    _EmbedderResult? preparedEmbedder,
    bool deb = false,
    bool ipk = false,
    bool targz = false,
    bool rpm = false,
    bool flatpak = false,
    String defaultName = 'app',
    List<String> selectedBackends = const [],
    String? appPath,
    String mode = 'release',
    bool? obfuscate,
    bool strip = true,
    bool tar = false,
    String? deployHost,
    String deployDir = 'ivi-homescreen',
    bool run = false,
    bool hostTools = false,
  }) async {
    final emb =
        preparedEmbedder ??
        await _buildEmbedder(
          profile,
          target,
          workspace,
          source,
          launcher: launcher,
          hostTools: hostTools,
          selectedBackends: selectedBackends,
          skipIfBuilt: true,
        );
    if (emb == null) return ExitCode.software.code;

    final built = emb.results;
    final buildRoot = emb.buildRoot;
    final builder = emb.builder;
    final overlayPaths = emb.overlayPaths;

    // Assemble a runnable bundle (embedder + engine + assets + libapp).
    // --deploy targets either an --app bundle (rsync) or a --deb (scp+install).
    if (deployHost != null && appPath == null && !deb) {
      _logger.err('--deploy needs --app or --deb (nothing to send).');
      return ExitCode.usage.code;
    }
    // `--deb --deploy` is scp + `apt-get install` on the board; adb reaches
    // boards that have neither. Fail here rather than after a full build.
    if (deployHost != null &&
        deb &&
        _deployTarget(deployHost, target.sysroot).transport ==
            DeviceTransport.adb) {
      _logger.err(
        '--deb --deploy needs the ssh transport (it installs with apt-get on '
        'the board). Use --app to push a runnable bundle over adb.',
      );
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
        obfuscate: obfuscate,
        strip: strip,
        tar: tar,
        deployHost: deployHost,
        deployDir: deployDir,
        run: run,
        flatpak: flatpak,
        defaultName: defaultName,
        manifestDir: source,
        overlayPrefix: overlayPaths?.prefix,
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
        overlayPaths?.prefix,
        deployHost: deployHost,
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
        overlayPaths?.prefix,
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
        overlayPaths?.prefix,
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
        overlayPaths?.prefix,
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

  /// The environment that points code-asset build hooks at the cross
  /// toolchain.
  ///
  /// Two kinds of hook need telling, by different means:
  ///
  ///   * a hook that drives CMake itself (`flatpak_dart`, `appstream_dart`)
  ///     calls plain `cmake`, which since 3.21 reads `CMAKE_TOOLCHAIN_FILE`
  ///     from the environment. The profile's generated toolchain file already
  ///     names the compilers, `CMAKE_SYSROOT` and the cpu flags, and
  ///     `CMAKE_SYSROOT` is enough for `pkg_check_modules` to resolve against
  ///     the sysroot rather than the host — so that one variable is the whole
  ///     fix, with no wrapper on PATH.
  ///
  ///   * a hook built on `native_toolchain_c` takes its compiler from
  ///     `CCompilerConfig`, which the patched SDK builds from
  ///     `FLUTTER_HOOK_CC`/`_AR`/`_LD`. That config carries **only paths**,
  ///     with nowhere for `--target`, `--sysroot` or the profile's flags, so
  ///     those point at wrappers that bake them in.
  ///
  /// Write wrapper scripts naming the cross toolchain for code-asset build
  /// hooks, and return the environment that points the SDK at them.
  ///
  /// A hook's compiler comes from `CCompilerConfig`, which carries **only
  /// paths** — there is nowhere in it for `--target`, `--sysroot`, or the rest
  /// of a cross profile's flags. So the flags go into wrappers, the same trick
  /// the CMake toolchain file uses for the embedder half.
  ///
  /// Needs an SDK that reads `FLUTTER_HOOK_CC`/`_AR`/`_LD` (meta-flutter's
  /// `0001-flutter_tools-let-a-caller-supply-the-code-asset-tool.patch`).
  /// Without it these are ignored, a hook resolves a *host* compiler, and
  /// `auditBundleLib` later rejects the wrong-architecture library — so
  /// [_warnIfSdkIgnoresHookToolchain] says so up front instead.
  /// A `cmake` wrapper for native builds, naming the overlay augments were
  /// installed into.
  ///
  /// Cross builds get this implicitly: their toolchain file sets
  /// `CMAKE_SYSROOT`, and `find_package` searches it. A native build has no
  /// toolchain file, so without this a hook that calls
  /// `find_package(<pkg> CONFIG)` misses an augment `emb` installed moments
  /// earlier — silently, since a hook that degrades rather than fails then
  /// produces a library with the augment's contribution simply absent.
  ///
  /// A wrapper on PATH rather than an exported variable, for the same reason
  /// [_writeHookToolchain] uses one: the hook runner replaces the environment,
  /// so an exported `CMAKE_PREFIX_PATH` never arrives. PATH does.
  ///
  /// Injected before the caller's own arguments, so a hook passing its own
  /// `-DCMAKE_PREFIX_PATH` still wins — CMake takes the last definition.
  ///
  /// Returns null when there is nothing to say: no overlay, or no `cmake`.
  Map<String, String>? _writeHookOverlayPrefix(
    CrossProfile profile,
    Directory buildRoot,
    Workspace workspace,
  ) {
    final realCmake = _which('cmake');
    if (realCmake == null) return null;

    // Augments install with CMAKE_INSTALL_PREFIX=/usr inside the overlay, so
    // the prefix to search is <overlay>/usr.
    final overlay = workspace.platformDir('overlay-${profile.targetTriple}');
    final prefix = Directory(p.join(overlay.path, 'usr'));
    if (!prefix.existsSync()) return null;

    final dir = Directory(p.join(buildRoot.path, 'hook-toolchain'))
      ..createSync(recursive: true);

    String q(String s) => "'${s.replaceAll("'", r"'\''")}'";

    File(p.join(dir.path, 'cmake')).writeAsStringSync(
      '#!/bin/sh\n'
      'configuring=true\n'
      'for arg in "\$@"; do\n'
      '    if [ "\$arg" = "--build" ]; then configuring=false; fi\n'
      'done\n'
      'ARGS=""\n'
      'if [ "\$configuring" = "true" ]; then\n'
      '    ARGS=${q('-DCMAKE_PREFIX_PATH=${prefix.path}')}\n'
      'fi\n'
      'exec ${q(realCmake)} \$ARGS "\$@"\n',
    );
    Process.runSync('chmod', ['+x', p.join(dir.path, 'cmake')]);

    final path = Platform.environment['PATH'];
    return {'PATH': path == null ? dir.path : '${dir.path}:$path'};
  }

  Map<String, String> _writeHookToolchain(
    CrossProfile profile,
    Directory buildRoot,
  ) {
    final dir = Directory(p.join(buildRoot.path, 'hook-toolchain'))
      ..createSync(recursive: true);

    String q(String s) => "'${s.replaceAll("'", r"'\''")}'";
    String flags(List<String> f) => f.map(q).join(' ');

    // --sysroot explicitly: profile.cFlags carries -B/-L/-I and rpath-link but
    // not this, and without it the linker cannot rebase the absolute paths
    // inside the sysroot's own libc.so linker script —
    // "cannot find /lib/aarch64-linux-gnu/libm.so.6". The CMake toolchain file
    // gets this for free from CMAKE_SYSROOT; a wrapper has to say it.
    final sysroot = profile.targetSysroot.isEmpty
        ? ''
        : '${q('--sysroot=${profile.targetSysroot}')} ';
    final cf = sysroot + flags(profile.cFlags);
    final lf = flags(profile.ldFlags);

    // Named `-gcc`/`-g++` rather than `cc`/`cxx` on purpose. CCompilerConfig
    // carries a C compiler, an archiver and a linker — no C++ driver — so a
    // hook that drives a CMake project (which needs CMAKE_CXX_COMPILER) has to
    // derive one, and the only handle it has is the compiler's own name. The
    // gcc→g++ substitution is the same inference flutter_tools makes in
    // reverse when it reads CMAKE_CXX_COMPILER out of a CMake cache.
    File wrapper(String name, String tool, String extraFlags) {
      final f = File(p.join(dir.path, name))
        ..writeAsStringSync(
          '#!/bin/sh\n'
          'for arg in "\$@"; do\n'
          '    if [ "\$arg" = "-c" ]; then\n'
          '        exec ${q(tool)} $cf "\$@"\n'
          '    fi\n'
          'done\n'
          'exec ${q(tool)} $cf $extraFlags "\$@"\n',
        );
      return f;
    }

    // native_toolchain_c compiles *and* links through the compiler and never
    // execs a linker, so both flag sets have to reach this one wrapper. Link
    // flags on a compile-only call make clang emit "linker input unused",
    // fatal for a hook built with -Werror — so add ldFlags only when this is
    // not a `-c` invocation.
    final ccFile = wrapper('emb-hook-gcc', profile.cc, lf);
    final cxxFile = wrapper('emb-hook-g++', profile.cxx, lf);

    // Invoked directly as `ar rc <lib> <objects>`.
    final arFile = File(p.join(dir.path, 'emb-hook-ar'))
      ..writeAsStringSync('#!/bin/sh\nexec ${q(profile.ar)} "\$@"\n');

    // CCompilerConfig requires a linker even though the C builder links
    // through the compiler driver. Give it the real one rather than a stub.
    final ldFile = File(p.join(dir.path, 'emb-hook-ld'))
      ..writeAsStringSync('#!/bin/sh\nexec ${q(_linkerFor(profile))} "\$@"\n');

    // A `cmake` wrapper on PATH, the same shape meta-flutter's
    // flutter-app-native.bbclass uses. A hook that drives a CMake project
    // (appstream_dart, flatpak_dart) calls plain `cmake`, and the toolchain
    // cannot reach it any other way: a hook runs with an environment the runner
    // controls, so an exported CMAKE_TOOLCHAIN_FILE is dropped — but PATH
    // survives, which is what makes wrapping the tool work.
    //
    // Injected on configure only. `cmake --build` must not be given -D
    // arguments, and the bbclass draws the same distinction.
    final realCmake = _which('cmake');
    final toolchain = profile.cmakeToolchainFile;
    if (realCmake != null && toolchain != null) {
      final pkg = profile.pkgConfig?.toEnv() ?? const <String, String>{};
      final exports = pkg.entries
          .map((e) => 'export ${e.key}=${q(e.value)}\n')
          .join();
      File(p.join(dir.path, 'cmake'))
        ..writeAsStringSync(
          '#!/bin/sh\n'
          '$exports'
          'configuring=true\n'
          'for arg in "\$@"; do\n'
          '    if [ "\$arg" = "--build" ]; then configuring=false; fi\n'
          'done\n'
          'ARGS=""\n'
          'if [ "\$configuring" = "true" ]; then\n'
          '    ARGS=${q('-DCMAKE_TOOLCHAIN_FILE=$toolchain')}\n'
          'fi\n'
          'exec ${q(realCmake)} \$ARGS "\$@"\n',
        )
        ..parent;
      Process.runSync('chmod', ['+x', p.join(dir.path, 'cmake')]);
    }

    for (final f in [ccFile, cxxFile, arFile, ldFile]) {
      Process.runSync('chmod', ['+x', f.path]);
    }
    // Only the FLUTTER_HOOK_* trio. Anything else set here would not reach a
    // hook: the runner gives hooks an environment it controls, so a
    // CMAKE_TOOLCHAIN_FILE or PKG_CONFIG_* exported here is silently dropped —
    // measured, not assumed. What survives is what the SDK reads itself and
    // passes on through the hook's config file.
    // PATH, so the cmake wrapper is found; arbitrary variables would not
    // survive, but PATH does.
    final path = Platform.environment['PATH'];
    return {
      'FLUTTER_HOOK_CC': ccFile.path,
      'FLUTTER_HOOK_AR': arFile.path,
      'FLUTTER_HOOK_LD': ldFile.path,
      'PATH': path == null ? dir.path : '${dir.path}:$path',
    };
  }

  /// Bare filenames of the code assets `flutter build bundle` produced for
  /// this bundle — the set the bundler flattens into `lib/`.
  static List<String> _stagedCodeAssetNames(Directory appBundle) {
    final dir = Directory(
      p.join(appBundle.path, 'data', 'flutter_assets', 'native_assets'),
    );
    if (!dir.existsSync()) return const [];
    try {
      return [
        for (final e in dir.listSync(recursive: true, followLinks: false))
          if (e is File) p.basename(e.path),
      ];
    } on FileSystemException {
      return const [];
    }
  }

  /// First [name] on PATH, or null.
  static String? _which(String name) {
    final r = Process.runSync('sh', ['-c', 'command -v $name']);
    if (r.exitCode != 0) return null;
    final out = (r.stdout as String).trim();
    return out.isEmpty ? null : out;
  }

  /// The cross linker. A profile names a compiler and an archiver but no
  /// linker; every toolchain that ships one puts it beside the compiler.
  /// Falls back to the compiler driver, which links correctly anyway.
  static String _linkerFor(CrossProfile profile) {
    final base = p
        .basename(profile.cc)
        .replaceAll(RegExp(r'-(gcc|clang)$'), '');
    final ld = p.join(p.dirname(profile.cc), '$base-ld');
    return File(ld).existsSync() ? ld : profile.cc;
  }

  /// Warn when the SDK predates the hook-toolchain patch, naming the cause up
  /// front rather than letting it surface later as an arch mismatch.
  void _warnIfSdkIgnoresHookToolchain(Workspace workspace) {
    final f = File(
      p.join(
        workspace.flutterDir.path,
        'packages/flutter_tools/lib/src/isolated/native_assets/linux/'
        'native_assets.dart',
      ),
    );
    if (!f.existsSync()) return;
    try {
      if (f.readAsStringSync().contains('FLUTTER_HOOK_CC')) return;
    } on FileSystemException {
      return;
    }
    _logger.warn(
      '  hook toolchain: this Flutter SDK does not read FLUTTER_HOOK_CC, so '
      'code-asset hooks will resolve a host compiler and produce '
      "wrong-architecture libraries. Apply meta-flutter's "
      '0001-flutter_tools-let-a-caller-supply-the-code-asset-tool.patch.',
    );
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
    bool? obfuscate,
    bool strip = true,
    String? overlayPrefix,
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
    // Offline: build the app against the store-rooted PUB_CACHE (populated by
    // `emb fetch --app`), and — under strict — inside the network namespace,
    // so `flutter build bundle` never reaches pub.dev.
    var appRunner = _runProcess;
    // Point code-asset build hooks at the cross toolchain. Without this a hook
    // compiles for the build host and the bundle audit below rejects it.
    //
    // A native build wants the host compiler, so it gets no compiler wrappers.
    // It still needs to be told where augments were installed, though: that
    // travels in the same `cmake` wrapper, and dropping the whole thing left a
    // hook's find_package() unable to see an overlay emb had just built for it.
    if (!native) {
      _warnIfSdkIgnoresHookToolchain(workspace);
      appRunner = withEnv(appRunner, _writeHookToolchain(profile, buildRoot));
    } else {
      final overlayEnv = _writeHookOverlayPrefix(profile, buildRoot, workspace);
      if (overlayEnv != null) appRunner = withEnv(appRunner, overlayEnv);
    }
    if (_offlineMode != OfflineMode.off) {
      appRunner = withEnv(appRunner, {
        'PUB_CACHE': storePubCacheDir(ensureCacheDir()).path,
      });
    }
    if (_offlineWrap) appRunner = netnsRunner(appRunner);

    final progress = _steps.start('Building app bundle ($mode/$arch)');
    final res = await buildAndAssemble(
      workspace: workspace,
      aot: _makeAot(workspace, host, runProcess: appRunner),
      bundle: _bundleFactory(workspace),
      engine: _engineFactory(workspace),
      appPath: appPath,
      arch: arch,
      mode: mode,
      outputDir: appBundle.path,
      build: true,
      obfuscate: obfuscate,
      strip: strip,
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

    // Verify the assembled bundle's lib/ holds only the engine, the app image,
    // and the declared module artifacts, each built for the target — before it
    // is copied to every runnable dir, tarball, flatpak, and deploy target.
    final audit = auditBundleLib(
      Directory(p.join(appBundle.path, 'lib')),
      triple: profile.targetTriple,
      moduleArtifacts: target.modules.expand((m) => m.artifacts),
      // What the stager copied in, read back from the same place it copied
      // from, so the two cannot drift.
      codeAssets: _stagedCodeAssetNames(appBundle),
    );
    if (!audit.ok) {
      // One line per file, not one per kind of fault: a host-built native asset
      // is usually both an arch mismatch and something emb never placed, and
      // reporting it twice reads as two unrelated nits rather than one broken
      // bundle.
      _logger.err(
        'App bundle is not usable on ${profile.targetTriple} — '
        '${audit.problems.length} file(s) in lib/ must be fixed:',
      );
      for (final problem in audit.problems) {
        _logger.err('  ${problem.describe()}');
      }
      _logger.err(
        'Rebuild these for ${profile.targetTriple}, or keep them out of the '
        'bundle. A native library the app genuinely needs belongs in '
        'cross.modules so emb cross-builds and audits it; one produced by a '
        'Dart build hook needs the hook to honor the cross toolchain.',
      );
      return ExitCode.software.code;
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
      final binArchErr = verifyElfForTriple(binary, profile.targetTriple);
      if (binArchErr != null) {
        _logger.err('  ${r.backend ?? ""}: embedder binary $binArchErr');
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
        // Ride-along project libraries: copy the embedder's DT_NEEDED shared
        // objects that resolve inside the backend's build tree (e.g.
        // libihs_shared) into the runnable's lib/. These are libraries the
        // embedder links but that no target package provides, so the loader
        // would not find them on the device. System/sysroot libraries do not
        // resolve in the build tree and are left to the target's own loader.
        final staged = await _stageLinkedLibs(
          binary: bin,
          buildDir: Directory(r.buildDir),
          profile: profile,
          libDir: Directory(p.join(outDir.path, 'lib')),
        );
        for (final err in staged.errors) {
          _logger.err('  ${r.backend ?? ""}: staged lib $err');
        }
        if (staged.errors.isNotEmpty) return ExitCode.software.code;
        for (final soname in staged.staged) {
          _logger.detail('  ${r.backend ?? ""}: staged lib/$soname');
        }
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
            overlayPrefix: overlayPrefix,
          );
          if (rc != ExitCode.success.code) return rc;
        }
        if (deployHost != null) {
          final dest = multi ? '$deployDir/${r.backend}' : deployDir;
          final rc = await _deploy(
            outDir,
            binName: p.basename(bin.path),
            device: _deployTarget(deployHost, target.sysroot),
            destDir: dest,
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
            // The assembled bundle's copy, not the build tree's: the
            // embedder's RUNPATH is $ORIGIN/lib, which only resolves
            // from here. See #185.
            final rc = await _runLocal(bin, outDir);
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

  /// Resolve the `--deploy` value plus the manifest device block into a
  /// [DeployTarget].
  ///
  /// SSH port/opts stay gated on `source: device` (they describe the rsync
  /// that scrapes the sysroot, and that is where they have always applied);
  /// the transport and adb serial are read whatever the source is, since
  /// pushing a bundle is a separate concern from sysroot provenance.
  DeployTarget _deployTarget(String value, SysrootSpec? spec) {
    final fromDevice = spec?.source == SysrootProvenance.device;
    return DeployTarget.parse(
      value,
      transport: spec?.transport ?? DeviceTransport.ssh,
      serial: spec?.adbSerial,
      port: fromDevice ? spec!.sshPort : 22,
      opts: fromDevice ? spec!.sshOpts : null,
    );
  }

  /// scp a built `.deb` to [host] and install it with `apt-get`, which
  /// resolves the package's `Depends:` from the device's own repos. The path
  /// for `--deb --deploy`. Assumes key-based SSH and non-interactive sudo (or a
  /// root login) on the target — the test-lab deploy path, not a hardened one.
  Future<int> _deployDeb(
    File deb, {
    required String host,
    required String bundleArch,
  }) async {
    final deployer = Deployer(runProcess: _runProcess);
    final boardArch = await deployer.remoteArch(DeployTarget.ssh(host));
    if (boardArch != null && !archMatches(bundleArch, boardArch)) {
      _logger.warn(
        'package arch is $bundleArch but $host reports $boardArch — apt will '
        'refuse it. Re-build with a matching --target for this board.',
      );
    }
    final remote = '/tmp/${p.basename(deb.path)}';
    final progress = _steps.start('Deploying → $host');
    final scp = await _runProcess('scp', [
      deb.path,
      '$host:$remote',
    ], output: ProcessOutputMode.stream);
    if (scp.exitCode != 0) {
      progress.fail('scp failed: ${scp.stderr}');
      return ExitCode.software.code;
    }
    // `apt-get install` of a local path (contains '/') installs the file and
    // pulls its Depends; clean up the staged copy afterwards.
    final install = await _runProcess('ssh', [
      host,
      'sudo apt-get install -y $remote; rc=\$?; rm -f $remote; exit \$rc',
    ], output: ProcessOutputMode.stream);
    if (install.exitCode != 0) {
      progress.fail('apt-get install failed: ${install.stderr}');
      return ExitCode.software.code;
    }
    progress.complete('Installed ${p.basename(deb.path)} on $host');
    return ExitCode.success.code;
  }

  /// Push [outDir] to [device]:[destDir] over its transport, then optionally
  /// run the embedder there.
  Future<int> _deploy(
    Directory outDir, {
    required String binName,
    required DeployTarget device,
    required String destDir,
    required String bundleArch,
    required bool run,
  }) async {
    final deployer = Deployer(runProcess: _runProcess);
    final label = device.label;

    // Catch the common footgun: pushing a wrong-arch bundle (e.g. a native
    // `--target local` build) to the board, which only fails at run time with
    // a cryptic `Exec format error`.
    final boardArch = await deployer.remoteArch(device);
    if (boardArch != null && !archMatches(bundleArch, boardArch)) {
      _logger.warn(
        'bundle arch is $bundleArch but $label reports $boardArch — '
        'the embedder will not run there. Re-build with a matching '
        '--target (cross sysroot) for this board.',
      );
    }

    final progress = _steps.start('Deploying → $label:$destDir');
    final res = await deployer.push(outDir, device: device, destDir: destDir);
    if (!res.success) {
      progress.fail(res.message ?? 'deploy failed');
      return ExitCode.software.code;
    }
    progress.complete('Deployed → $label:$destDir (via ${res.method})');
    if (device.transport == DeviceTransport.adb) {
      // adb has no rsync --delete, so a file dropped from the bundle since the
      // last push survives on the board. Say so rather than let it surface as
      // a stale asset at run time.
      _logger.detail(
        '  adb push overlays the destination (no --delete): use a fresh '
        '--deploy-dir if a removed file must not linger.',
      );
    }
    final runCmd = './$binName -b .';
    if (!run) {
      final argv = deployer.runArgv(device, destDir, runCmd);
      _logger.info('  run on target: ${argv.join(' ')}');
      return ExitCode.success.code;
    }
    _logger.info('  running on $label …');
    final argv = deployer.runArgv(device, destDir, runCmd);
    final proc = await Process.start(
      argv.first,
      argv.sublist(1),
      mode: ProcessStartMode.inheritStdio,
    );
    return proc.exitCode;
  }

  /// Launch the native [embedder] from inside [bundle] on this host
  /// (`./<embedder> -b .`), inheriting stdio. Used by `--run` for a
  /// `--target local` build, where there is no deploy step.
  ///
  /// [embedder] must be the bundle's own copy, not the one left in the build
  /// tree. The embedder is linked with RUNPATH `$ORIGIN/lib:$ORIGIN`, and only
  /// the assembled bundle has the layout that satisfies it: in the build tree a
  /// project library such as libihs_shared sits in a sibling directory rather
  /// than in `lib/`, so launching from there dies in the loader before main.
  ///
  /// Runs with the bundle as the working directory, so the invocation is the
  /// one printed when the bundle is assembled.
  Future<int> _runLocal(File embedder, Directory bundle) async {
    final exe = './${p.basename(embedder.path)}';
    _logger.info('  running $exe -b . in ${bundle.path} …');
    final proc = await Process.start(
      exe,
      ['-b', '.'],
      workingDirectory: bundle.path,
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

  /// Copy [binary]'s `DT_NEEDED` shared libraries that are provided by the
  /// project's own [buildDir] (rather than the target sysroot) into [libDir],
  /// following each staged library's own `DT_NEEDED` transitively.
  ///
  /// A soname that does not resolve to a file under [buildDir] is a system /
  /// sysroot library the target's loader already provides, and is skipped. Each
  /// staged object is verified to match the target triple so a stray host-arch
  /// build cannot ride along. Returns the staged sonames and any per-lib
  /// errors.
  Future<_StagedLibs> _stageLinkedLibs({
    required File binary,
    required Directory buildDir,
    required CrossProfile profile,
    required Directory libDir,
  }) async {
    // Index every *.so* in the build tree by soname (basename); following
    // symlinks so a soname link (libfoo.so.1) resolves to its real object.
    final byName = <String, File>{};
    if (buildDir.existsSync()) {
      try {
        for (final e in buildDir.listSync(recursive: true)) {
          if (e is! File) continue;
          final base = p.basename(e.path);
          if (base.contains('.so')) byName.putIfAbsent(base, () => e);
        }
      } on FileSystemException {
        // Broken symlink or unreadable entry mid-walk: index what we can.
      }
    }

    final readelf = _readelfFor(profile);
    final staged = <String>[];
    final errors = <String>[];
    final seen = <String>{};
    final queue = <File>[binary];
    while (queue.isNotEmpty) {
      final elf = queue.removeLast();
      final r = await _runProcess(readelf, [
        '-d',
        elf.path,
      ], environment: profile.buildEnv());
      if (r.exitCode != 0) continue;
      for (final soname in parseNeededSonames(r.stdout)) {
        if (!seen.add(soname)) continue;
        final src = byName[soname];
        if (src == null) continue; // system/sysroot lib — loader handles it
        final archErr = verifyElfForTriple(src, profile.targetTriple);
        if (archErr != null) {
          errors.add('$soname: $archErr');
          continue;
        }
        libDir.createSync(recursive: true);
        final dest = File(p.join(libDir.path, soname));
        src.copySync(dest.path); // copySync follows the symlink to real content
        staged.add(soname);
        queue.add(dest); // a staged lib may pull in more in-tree libraries
      }
    }
    return _StagedLibs(staged, errors);
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
    String? overlayPrefix, {
    String? deployHost,
  }) async {
    final spec = target.package ?? const PackageSpec();
    final arch = debianArch(profile.targetTriple);
    final baseName = spec.name ?? defaultName;
    final outDir = Directory(p.join(buildRoot.path, 'dist'));
    // The resolver's downloaded `.deb`s sit beside the sysroot, in `debs/`.
    final debDirs = [
      Directory(p.join(p.dirname(profile.targetSysroot), 'debs')),
    ];
    // Extra files resolved against the manifest dir → absolute target paths.
    final ef = _extraFiles(
      spec,
      manifestDir,
      overlayPrefix: overlayPrefix,
      defines: target.defines,
    );
    // Maintainer scripts (preinst/postinst/prerm/postrm) → DEBIAN/<name>.
    final maintainerScripts = {
      for (final e in spec.scripts.entries)
        e.key: p.join(manifestDir.path, e.value),
    };
    final packager = DebPackager(
      readelf: _readelfFor(profile),
      runProcess: withEnv(_runProcess, profile.buildEnv()),
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

      // bundle_libs: stage the binary's in-tree .so closure into the package
      // under /usr/lib/<multiarch>/ (a default loader path, so no rpath needed).
      // Sysroot/system libs are skipped by _stageLinkedLibs and must be covered
      // by depends:.
      final extraFiles = {...ef.files};
      final extraModes = {...ef.modes};
      if (spec.bundleLibs) {
        final libStage = Directory(p.join(buildRoot.path, 'deb-libs', name));
        if (libStage.existsSync()) libStage.deleteSync(recursive: true);
        libStage.createSync(recursive: true);
        final staged = await _stageLinkedLibs(
          binary: binary,
          buildDir: Directory(r.buildDir),
          profile: profile,
          libDir: libStage,
        );
        for (final e in staged.errors) {
          _logger.warn('  bundle_libs: $e');
        }
        final mad = debianMultiarch(profile.targetTriple);
        for (final soname in staged.staged) {
          extraFiles[p.join(libStage.path, soname)] = '/usr/lib/$mad/$soname';
        }
        if (staged.staged.isNotEmpty) {
          _logger.info(
            '  bundled libs  : ${staged.staged.join(", ")} → /usr/lib/$mad',
          );
        }
      }

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
          extraFiles: extraFiles,
          fileModes: extraModes,
          maintainerScripts: maintainerScripts,
        );
        _logger.info('  ${r.backend ?? ""}: packaged → ${out.path}');
        if (deployHost != null) {
          final rc = await _deployDeb(out, host: deployHost, bundleArch: arch);
          if (rc != ExitCode.success.code) return rc;
        }
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
    String? overlayPrefix,
  ) async {
    final spec = target.package ?? const PackageSpec();
    final arch = spec.ipk?.arch ?? opkgArch(profile.targetTriple);
    final baseName = spec.name ?? defaultName;
    final outDir = Directory(p.join(buildRoot.path, 'dist'));
    final ef = _extraFiles(
      spec,
      manifestDir,
      overlayPrefix: overlayPrefix,
      defines: target.defines,
    );
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
    String? overlayPrefix,
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
    final ef = _extraFiles(
      spec,
      manifestDir,
      overlayPrefix: overlayPrefix,
      defines: target.defines,
    );
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
    String? overlayPrefix,
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
    final ef = _extraFiles(
      spec,
      manifestDir,
      overlayPrefix: overlayPrefix,
      defines: target.defines,
    );
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
    String? overlayPrefix,
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
    final ef = _extraFiles(
      spec,
      manifestDir,
      overlayPrefix: overlayPrefix,
      defines: target.defines,
    );
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
      env: fp.env,
      args: fp.args,
    );
    // Resolved before packaging so a missing runtime fails before any work,
    // but applied to the packager's staged copy — the runnable this was handed
    // is the same tree --tar, --deploy and --run use, and libraries chosen for
    // a flatpak runtime have no business on a device.
    final ({
      FlatpakLibVendor vendor,
      Directory runtimeFiles,
      List<Directory> searchPaths,
    })?
    vendorStep;
    if (fp.vendorLibs) {
      vendorStep = await _flatpakVendorStep(profile, meta: fp, arch: fpArch);
      if (vendorStep == null) return ExitCode.software.code;
    } else {
      vendorStep = null;
    }
    final outDir = Directory(p.join(buildRoot.path, 'dist'));
    final label = '${tag}Packaging flatpak ($appId)';
    final progress = _steps.start(label);
    // Vendoring runs inside build(), so it is already under the step above: it
    // revises that label rather than starting a second, concurrent spinner, and
    // parks its diagnostics here to be printed once the step has settled —
    // warning over a live spinner writes over the line it is drawing.
    final notes = <void Function()>[];
    final step = vendorStep;
    try {
      final out = await FlatpakPackager(runProcess: _runProcess).build(
        bundleDir: bundleDir,
        meta: meta,
        outDir: outDir,
        extraFiles: ef.files,
        fileModes: ef.modes,
        onStaged: step == null
            ? null
            : (stagedBundle) => _runVendorStep(
                step,
                stagedBundle,
                embedder: embedder,
                tag: tag,
                progress: progress,
                label: label,
                notes: notes,
              ),
      );
      progress.complete('${tag}flatpak → ${out.path}');
      return ExitCode.success.code;
    } on FlatpakPackageException catch (e) {
      progress.fail('$tag${e.message}');
      return ExitCode.software.code;
    } on FlatpakVendorException catch (e) {
      progress.fail('$tag${e.message}');
      return ExitCode.software.code;
    } finally {
      for (final note in notes) {
        note();
      }
    }
  }

  /// Resolve everything `cross.package.flatpak.vendor_libs` needs, or null when
  /// the runtime is not installed.
  ///
  /// The runtime is the deployment environment here, not the sysroot the build
  /// linked against, and it ships a much narrower library set — so the closure
  /// has to be recomputed against it. That needs the runtime present on the
  /// build host: without it there is nothing to subtract, and vendoring the
  /// whole closure would ship a second copy of libc.
  Future<
    ({
      FlatpakLibVendor vendor,
      Directory runtimeFiles,
      List<Directory> searchPaths,
    })?
  >
  _flatpakVendorStep(
    CrossProfile profile, {
    required FlatpakPackageSpec meta,
    required String? arch,
  }) async {
    final ref = arch == null
        ? '${meta.runtime}//${meta.runtimeVersion}'
        : '${meta.runtime}/$arch/${meta.runtimeVersion}';
    final loc = await _runProcess('flatpak', ['info', '--show-location', ref]);
    if (loc.exitCode != 0) {
      _logger.err(
        '  vendor_libs needs the runtime installed to know what it already '
        'provides — install it with:\n'
        '    flatpak install $ref',
      );
      return null;
    }
    final runtimeFiles = Directory(p.join(loc.stdout.trim(), 'files'));
    if (!runtimeFiles.existsSync()) {
      _logger.err('  runtime tree has no files/: ${runtimeFiles.path}');
      return null;
    }

    // The sysroot is where a missing soname is looked up: it holds the same
    // libraries the embedder linked against, so the vendored copy is the one it
    // was built for. `--target local` resolves an empty sysroot meaning "the
    // host root", which is both correct (build host == runtime host) and a trap
    // — joining onto '' yields relative paths that resolve against the cwd.
    final sysroot = profile.targetSysroot.isEmpty ? '/' : profile.targetSysroot;
    final searchPaths = [
      for (final rel in ['lib', 'lib64', 'usr/lib', 'usr/lib64'])
        Directory(p.join(sysroot, rel)),
    ].where((d) => d.existsSync()).toList();

    return (
      vendor: FlatpakLibVendor(
        readelf: _readelfFor(profile),
        triple: profile.targetTriple,
        runProcess: _runProcess,
        environment: profile.buildEnv(),
      ),
      runtimeFiles: runtimeFiles,
      searchPaths: searchPaths,
    );
  }

  /// Run the resolved vendoring step against the flatpak's staged bundle.
  ///
  /// Called from inside `FlatpakPackager.build`, which the caller has already
  /// wrapped in [progress]. So this borrows that handle instead of opening one
  /// of its own — it never completes or fails it, and restores [label] on the
  /// way out so the caller's own settle reads correctly whether vendoring
  /// succeeded or threw. Diagnostics go to [notes] for the caller to print once
  /// the step has settled.
  Future<void> _runVendorStep(
    ({
      FlatpakLibVendor vendor,
      Directory runtimeFiles,
      List<Directory> searchPaths,
    })
    step,
    Directory stagedBundle, {
    required String embedder,
    required String tag,
    required StepHandle progress,
    required String label,
    required List<void Function()> notes,
  }) async {
    progress.update('${tag}Vendoring libs not in the runtime');
    final VendorReport report;
    try {
      report = await step.vendor.vendor(
        bundleDir: stagedBundle,
        command: embedder,
        runtimeFiles: step.runtimeFiles,
        searchPaths: step.searchPaths,
      );
    } finally {
      progress.update(label);
    }
    notes.add(() {
      _logger.info(
        '  ${tag}Vendored ${report.staged.length} lib(s); '
        '${report.provided.length} from the runtime',
      );
      for (final soname in report.staged) {
        _logger.detail('  vendored lib/$soname');
      }
      // Not fatal: a dlopen-only plugin has no DT_NEEDED entry either way, and
      // a device may supply a library outside the sysroot. But each one is a
      // candidate startup failure, so say it out loud, not under --verbose.
      for (final soname in report.unresolved) {
        _logger.warn(
          '  $tag$soname: not in the runtime and not on the sysroot — the app '
          'will fail to start if it is really needed',
        );
      }
    });
  }

  /// Resolve [spec]'s `files:` against [manifestDir] into a (host source →
  /// dest) map and a (host source → octal mode) map. The mode is the entry's
  /// explicit `mode:`, else the source file's own mode (so an executable stays
  /// executable and a shared object stays 0644 without spelling it out).
  ///
  /// A source naming a directory contributes every file beneath it; see
  /// [expandPackageFiles].
  ({Map<String, String> files, Map<String, String> modes}) _extraFiles(
    PackageSpec spec,
    Directory manifestDir, {
    String? overlayPrefix,
    Map<String, String> defines = const {},
  }) {
    final entries = <PackageFileEntry>[];
    for (final e in spec.files.entries) {
      // Skip a file gated on an embedder define that isn't satisfied (e.g.
      // crashpad_handler unless BUILD_CRASH_HANDLER=ON) -- its source may not
      // even exist because the gated augment that stages it was skipped.
      if (!CrossTarget.defineSatisfied(spec.fileRequires[e.key], defines)) {
        continue;
      }
      // A source under `overlay/` names an augment-staged artifact (e.g.
      // `overlay/usr/bin/crashpad_handler`) and resolves against the overlay
      // prefix; everything else is manifest-relative. The overlay stages into
      // `<prefix>/usr/...`, so strip the leading `overlay/` segment.
      final String src;
      if (e.key == 'overlay' || e.key.startsWith('overlay/')) {
        if (overlayPrefix == null) {
          _logger.err(
            '  package.files: "${e.key}" references the augment overlay, but '
            'none was built for this target (add an augment or drop the entry)',
          );
          continue;
        }
        src = p.join(overlayPrefix, e.key.substring('overlay/'.length));
      } else {
        src = p.join(manifestDir.path, e.key);
      }
      entries.add((src: src, dest: e.value, mode: spec.fileModes[e.key]));
    }
    final expanded = expandPackageFiles(entries, modeOf: _octal);
    for (final w in expanded.warnings) {
      _logger.warn('  package.files: $w');
    }
    return (files: expanded.files, modes: expanded.modes);
  }

  /// The file's permission bits as a 4-digit octal string (e.g. `0755`).
  String _octal(File f) =>
      '0${(f.statSync().mode & 0x1FF).toRadixString(8).padLeft(3, '0')}';

  static String _sourceFingerprint(Directory dir) => sourceFingerprint(dir);

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
        final archErr = verifyElfForTriple(staged, profile.targetTriple);
        if (archErr != null) {
          _logger.err('  module ${m.name}: artifact "$soname" $archErr');
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
    final offline = _offlineMode != OfflineMode.off;
    final env = {
      ...cargoEnv(profile, triple),
      'CARGO_TARGET_DIR': buildDir.path,
      // A fast-fail under an offline build: cargo errors immediately on a
      // needed registry/git fetch instead of hanging on a network timeout.
      if (offline) 'CARGO_NET_OFFLINE': '1',
    };
    // Offline: build against the crates vendored by `emb fetch`. A CARGO_HOME
    // holding only the vendor config redirects crates-io to the on-disk vendor
    // dir; without it, `cargo --offline` fails with its own missing crate.
    if (offline) {
      final home = CargoVendor(
        run: _runProcess,
      ).locate(moduleSrc: src, storeRoot: ensureCacheDir());
      if (home != null) env['CARGO_HOME'] = home.path;
    }
    // Best-effort: install the target's std (idempotent; no-op without rustup).
    // Skipped offline — it would reach rustup's dist server.
    if (!offline) {
      try {
        await _runProcess('rustup', ['target', 'add', triple]);
      } on ProcessException {
        // No rustup — assume the target std is present, else cargo will error.
      }
    }
    // Under --offline-strict (on a host with the capability) the build runs in
    // a network namespace, so a crate build script that tries the network is
    // denied rather than trusted to honor --offline. unshare inherits the cwd
    // and env, so CARGO_HOME/CARGO_NET_OFFLINE still reach cargo.
    final run = _offlineWrap ? netnsRunner(_runProcess) : _runProcess;
    final r = await run(
      'cargo',
      [
        'build',
        '--release',
        '--target',
        triple,
        if (offline) '--offline',
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
    required List<String> requestedTags,
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
    final skopeo = await _hasExecutable('skopeo');
    if (!await _refExists(plan, skopeoAvailable: skopeo)) {
      return false;
    }

    // The content is published. That is not sufficient: every other tag the
    // caller asked for is mutable, and skipping here is what leaves one of
    // them pointing at an older image forever -- the content tag keeps
    // matching, so the skip keeps firing, and the stale name is never
    // corrected. Anything consuming the image by that name gets the old one.
    //
    // So compare digests rather than existence. A tag that is missing, points
    // elsewhere, or cannot be read means the publish still has work to do, and
    // the full path below applies every tag.
    final wanted = await _refDigest(
      plan,
      plan.primaryRef,
      skopeoAvailable: skopeo,
    );
    for (final tag in requestedTags.where((t) => t != imageTag)) {
      final ref = '$image:$tag';
      final actual = await _refDigest(plan, ref, skopeoAvailable: skopeo);
      if (wanted == null || actual != wanted) {
        _logger.info(
          '$ref does not point at ${plan.primaryRef} — '
          'republishing to move it.',
        );
        return false;
      }
    }

    _logger.info('${plan.primaryRef} already published — skipping resolve.');
    return true;
  }

  /// The digest [ref] resolves to, or null when it cannot be read.
  ///
  /// Null is deliberately not "they differ" at the call site: it is treated as
  /// a reason to republish, because a skip that cannot verify what it is
  /// skipping is the failure this exists to prevent.
  Future<String?> _refDigest(
    ImagePublishPlan plan,
    String ref, {
    required bool skopeoAvailable,
  }) async {
    final probe = plan.digestProbe(ref, skopeoAvailable: skopeoAvailable);
    try {
      final r = await _runProcess(probe.exe, probe.args);
      if (r.exitCode != 0) return null;
      final out = (r.stdout as String?) ?? '';
      // skopeo --format prints the digest alone; `manifest inspect --verbose`
      // embeds it in JSON, so take the first sha256 either way rather than
      // parsing two shapes.
      final match = RegExp('sha256:[0-9a-f]{64}').firstMatch(out);
      return match?.group(0);
    } on ProcessException {
      return null;
    }
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

/// Outcome of [CrossCommand._buildEmbedder]: everything downstream (`_build`,
/// `_runnable`, packaging) needs to continue after the embedder build.
class _EmbedderResult {
  const _EmbedderResult({
    required this.results,
    required this.buildRoot,
    required this.builder,
    this.overlayPaths,
  });

  final List<CrossBuildResult> results;
  final Directory buildRoot;
  final CrossBuilder builder;
  final OverlayPaths? overlayPaths;
}

/// Result of staging an embedder's project-built `DT_NEEDED` libraries into a
/// runnable bundle: the staged sonames and any per-library errors (e.g. an
/// arch mismatch), collected so the caller can fail the build with all of them.
class _StagedLibs {
  const _StagedLibs(this.staged, this.errors);
  final List<String> staged;
  final List<String> errors;
}
