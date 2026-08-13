import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:emb_cli/src/aot/aot_builder.dart';
import 'package:emb_cli/src/bundle/bundle_builder.dart';
import 'package:emb_cli/src/bundle/bundle_pipeline.dart';
import 'package:emb_cli/src/cache/cache_dir.dart';
import 'package:emb_cli/src/engine/engine_artifacts.dart';
import 'package:emb_cli/src/exec/container_reentry.dart';
import 'package:emb_cli/src/host/host_info.dart';
import 'package:emb_cli/src/manifest/manifest_loader.dart';
import 'package:emb_cli/src/workspace/workspace.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:path/path.dart' as p;

/// {@template build_command}
/// `emb build <package>` — build a self-describing package's app into bundles
/// for every target arch × mode declared in its manifest `build:` block, so no
/// `--app-path`/`--arch`/`--mode` flags are needed.
/// {@endtemplate}
class BuildCommand extends Command<int> {
  /// {@macro build_command}
  BuildCommand({
    required Logger logger,
    HostInfo? host,
    ManifestLoader loader = const ManifestLoader(),
    AotBuilder Function(Workspace ws, HostInfo host)? aotFactory,
    BundleBuilder Function(Workspace ws)? bundleFactory,
    EngineArtifacts Function(Workspace ws)? engineFactory,
    ContainerReentry? reentry,
  }) : _logger = logger,
       _host = host,
       _loader = loader,
       _reentry = reentry,
       _aotFactory = aotFactory ?? ((ws, host) => AotBuilder(ws, host: host)),
       _bundleFactory = bundleFactory ?? BundleBuilder.new,
       _engineFactory = engineFactory ?? EngineArtifacts.new {
    argParser
      ..addOption(
        'workspace',
        abbr: 'w',
        help: r'Workspace root (defaults to $FLUTTER_WORKSPACE or cwd).',
      )
      ..addMultiOption(
        'arch',
        help: 'Override the target arch(es) from the manifest.',
      )
      ..addMultiOption(
        'mode',
        abbr: 'm',
        help: 'Override the mode(s) from the manifest.',
        allowed: const ['debug', 'profile', 'release'],
      )
      ..addFlag(
        'no-build',
        help: 'Assemble from existing artifacts; skip compiling.',
        negatable: false,
      )
      ..addFlag(
        'exec-native',
        help:
            'Run directly instead of routing through a container (set '
            'automatically inside the container; recursion guard).',
        negatable: false,
        hide: true,
      );
  }

  final Logger _logger;
  final HostInfo? _host;
  final ManifestLoader _loader;
  final ContainerReentry? _reentry;
  final AotBuilder Function(Workspace ws, HostInfo host) _aotFactory;
  final BundleBuilder Function(Workspace ws) _bundleFactory;
  final EngineArtifacts Function(Workspace ws) _engineFactory;

  @override
  String get description =>
      'Build a self-describing package (manifest build: config) into bundles.';

  @override
  String get name => 'build';

  @override
  Future<int> run() async {
    final args = argResults!;
    final rest = args.rest;
    if (rest.isEmpty) {
      _logger.err(
        'Usage: emb build <package-dir> '
        '(a dir with emb.yaml or pubspec.yaml emb:)',
      );
      return ExitCode.usage.code;
    }
    final host = _host ?? HostInfo.detect();
    final workspace = Workspace.resolve(override: args['workspace'] as String?);

    final pkgDir = Directory(rest.first);
    final manifest = _loader.loadPackageDir(pkgDir);
    if (manifest == null) {
      _logger.err(
        'No emb manifest in ${pkgDir.path} '
        '(expected emb.yaml or an emb: key in pubspec.yaml).',
      );
      return ExitCode.usage.code;
    }
    final build = manifest.build;
    if (build == null) {
      _logger.err('${manifest.id} has no build: config in its manifest.');
      return ExitCode.usage.code;
    }

    // Resolve the matrix: CLI overrides win, else the manifest, else defaults.
    final appPath = p.normalize(p.join(pkgDir.absolute.path, build.appPath));
    final archs = (args['arch'] as List<String>).ifEmpty(
      build.archs.isEmpty ? [host.machineArch] : build.archs,
    );
    final modes = (args['mode'] as List<String>).ifEmpty(build.modes);

    if (!Directory(appPath).existsSync()) {
      _logger.err('App path not found: $appPath');
      return ExitCode.usage.code;
    }

    // The whole matrix compiles via the Linux-x86_64 toolchain; on a non-Linux
    // / non-x86_64 host, route the whole `emb build` through the runtime
    // container once. Re-pass the raw --arch/--mode so the manifest matrix
    // resolves identically inside (don't substitute the host-arch fallback).
    final reentry = _reentry ?? ContainerReentry(host: host);
    final routed = await reentry.maybeRun(
      forceNative: args['exec-native'] as bool,
      workdir: workspace.root.path,
      mounts: ContainerReentry.mountsFor([
        workspace.root.path,
        pkgDir.absolute.path,
        ensureCacheDir().path,
      ]),
      embArgs: [
        'build',
        pkgDir.absolute.path,
        '-w',
        workspace.root.path,
        for (final a in args['arch'] as List<String>) ...['--arch', a],
        for (final m in args['mode'] as List<String>) ...['--mode', m],
        if (args['no-build'] as bool) '--no-build',
      ],
    );
    if (routed != null) return routed;

    _logger.info(
      styleBold.wrap(
        'Building ${manifest.id}: '
        'archs=${archs.join(",")} modes=${modes.join(",")}',
      ),
    );

    var failures = 0;
    for (final arch in archs) {
      for (final mode in modes) {
        final out = build.output != null
            ? p.join(
                workspace.root.path,
                build.output,
                '${manifest.id}-$mode-${EngineArtifacts.engineArch(arch)}',
              )
            : defaultBundleOutput(workspace, appPath, mode, arch);

        final progress = _logger.progress('$mode/$arch');
        final result = await buildAndAssemble(
          workspace: workspace,
          aot: _aotFactory(workspace, host),
          bundle: _bundleFactory(workspace),
          engine: _engineFactory(workspace),
          appPath: appPath,
          arch: arch,
          mode: mode,
          outputDir: out,
          build: !(args['no-build'] as bool),
          onStep: progress.update,
        );
        if (result.success) {
          progress.complete('$mode/$arch → ${result.outputDir}');
        } else {
          failures++;
          progress.fail('$mode/$arch failed');
          if (result.message != null) _logger.err(' ${result.message}');
          for (final m in result.missing) {
            _logger.err(' - $m');
          }
        }
      }
    }

    if (failures > 0) {
      _logger.err('$failures build(s) failed.');
      return ExitCode.software.code;
    }
    _logger.info(lightGreen.wrap('All bundles built.'));
    return ExitCode.success.code;
  }
}

extension _IfEmpty on List<String> {
  List<String> ifEmpty(List<String> fallback) => isEmpty ? fallback : this;
}
