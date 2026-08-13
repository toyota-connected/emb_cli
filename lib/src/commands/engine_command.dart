import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:emb_cli/src/cache/cache_dir.dart';
import 'package:emb_cli/src/cache/store.dart';
import 'package:emb_cli/src/commands/positional_args.dart';
import 'package:emb_cli/src/engine/engine_abi_gate.dart';
import 'package:emb_cli/src/engine/engine_artifacts.dart';
import 'package:emb_cli/src/engine/engine_builder.dart';
import 'package:emb_cli/src/engine/engine_toolchain.dart';
import 'package:emb_cli/src/exec/container_launcher.dart';
import 'package:emb_cli/src/exec/exec_env.dart';
import 'package:emb_cli/src/host/host_info.dart';
import 'package:emb_cli/src/workspace/workspace.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:path/path.dart' as p;

/// {@template engine_command}
/// `emb engine` — provision Flutter engine runtime artifacts.
///
/// Default mode is **auto**: download the prebuilt engine SDK for the resolved
/// commit when published, otherwise report that a source build is required.
/// With `--build-engine`, an unavailable mode is built from source and adopted
/// into the shared store as a drop-in (opt-in; only flutter-engine CI should
/// build in CI).
/// {@endtemplate}
class EngineCommand extends Command<int> {
  /// {@macro engine_command}
  EngineCommand({
    required Logger logger,
    HostInfo? host,
    EngineArtifacts Function(Workspace ws)? engineFactory,
    EngineBuildFn? engineBuild,
    ContainerLauncher? containerLauncher,
  }) : _logger = logger,
       _host = host,
       _engineFactory = engineFactory ?? EngineArtifacts.new,
       _engineBuild = engineBuild,
       _containerLauncher = containerLauncher {
    argParser
      ..addOption(
        'workspace',
        abbr: 'w',
        help: r'Workspace root (defaults to $FLUTTER_WORKSPACE or cwd).',
      )
      ..addOption(
        'commit',
        help:
            'Engine commit (defaults to '
            '<workspace>/flutter/bin/internal/engine.version).',
      )
      ..addOption(
        'arch',
        help: 'Engine arch token (defaults to the host arch).',
      )
      ..addMultiOption(
        'mode',
        abbr: 'm',
        help:
            'Runtime modes to fetch (others are auto-fetched on demand by '
            '`emb bundle`/`build`).',
        allowed: engineRuntimeModes,
        defaultsTo: const ['release'],
      )
      ..addFlag(
        'clean',
        help: 're-stage bundles even when already present.',
        negatable: false,
      )
      ..addFlag(
        'check',
        help: 'Only check prebuilt availability; do not download.',
        negatable: false,
      )
      ..addFlag(
        'build-engine',
        help:
            'Build the engine from source when no prebuilt is published, and '
            'adopt it into the shared store (opt-in; slow).',
        negatable: false,
      )
      ..addOption(
        'libc',
        allowed: const ['glibc', 'musl'],
        defaultsTo: 'glibc',
        help: 'Target C library / ABI for a source build (glibc | musl).',
      )
      ..addOption(
        'sysroot-id',
        help:
            'Sysroot flavour for musl targets (e.g. poky | alpine); folded '
            'into the artifact key.',
      )
      ..addFlag(
        'no-verify-abi',
        help: 'Skip the post-build ABI gate on libflutter_engine.so.',
        negatable: false,
      )
      ..addFlag(
        'offline',
        help:
            'Build from the fetched closure with the network denied '
            '(run `emb engine fetch` first).',
        negatable: false,
      )
      ..addFlag(
        'offline-strict',
        help:
            'Like --offline, but sandbox the build in a network namespace and '
            'refuse when that isolation is unavailable.',
        negatable: false,
      )
      ..addFlag(
        'exec-native',
        help:
            'Run the build directly instead of routing through a container '
            '(set automatically inside the container; recursion guard).',
        negatable: false,
        hide: true,
      );
  }

  final Logger _logger;
  final HostInfo? _host;
  final EngineArtifacts Function(Workspace ws) _engineFactory;
  final EngineBuildFn? _engineBuild;
  final ContainerLauncher? _containerLauncher;

  @override
  String get description =>
      'Fetch prebuilt Flutter engine artifacts (auto fetch-else-build).';

  @override
  String get name => 'engine';

  @override
  Future<int> run() async {
    rejectPositionals(this);
    final args = argResults!;
    final host = _host ?? HostInfo.detect();
    final workspace = Workspace.resolve(override: args['workspace'] as String?);

    final commit = (args['commit'] as String?) ?? workspace.engineCommit();
    if (commit == null || commit.isEmpty) {
      _logger.err(
        'Could not determine the engine commit. '
        'Provide --commit or ensure '
        '${workspace.flutterDir.path}/bin/internal/engine.version exists.',
      );
      return ExitCode.usage.code;
    }
    // Determine the proper engine SDK arch token for this machine (or honor
    // an explicit --arch for cross-fetching a target architecture).
    final arch = EngineArtifacts.engineArch(
      (args['arch'] as String?) ?? host.machineArch,
    );
    final modes = args['mode'] as List<String>;
    final buildEngine = args['build-engine'] as bool;
    final verifyAbi = !(args['no-verify-abi'] as bool);
    final strict = args['offline-strict'] as bool;
    final offline = (args['offline'] as bool) || strict;
    final libc = Libc.fromToken(args['libc'] as String);
    final sysrootId = args['sysroot-id'] as String?;
    final profile = (libc == Libc.glibc && sysrootId == null)
        ? ToolchainProfile.linuxGlibc
        : ToolchainProfile(
            os: TargetOs.linux,
            libc: libc,
            sysrootId: sysrootId,
          );
    final inContainer =
        (args['exec-native'] as bool) ||
        Platform.environment.containsKey('EMB_IN_CONTAINER');

    _logger.info(
      'Engine commit: $commit arch: $arch '
      '(host: ${host.machineArch}) modes: ${modes.join(", ")}',
    );

    final engine = _engineFactory(workspace);
    var anyBuildNeeded = false;
    var anyFailed = false;
    try {
      for (final mode in modes) {
        if (args['check'] as bool) {
          final available = await engine.isAvailable(mode, arch, commit);
          _logger.info(' $mode: ${available ? "available" : "NOT published"}');
          if (!available) anyBuildNeeded = true;
          continue;
        }

        final progress = _logger.progress('Engine $mode');
        final result = await engine.fetch(
          runtime: mode,
          arch: arch,
          commit: commit,
          clean: args['clean'] as bool,
        );
        switch (result.status) {
          case EngineFetchStatus.fetched:
            progress.complete('Engine $mode → ${result.bundleDir}');
          case EngineFetchStatus.upToDate:
            progress.complete('Engine $mode already up to date');
          case EngineFetchStatus.unavailable:
            final built =
                buildEngine &&
                await _tryBuild(
                  host: host,
                  workspace: workspace,
                  commit: commit,
                  arch: arch,
                  mode: mode,
                  progress: progress,
                  verifyAbi: verifyAbi,
                  inContainer: inContainer,
                  offline: offline,
                  strict: strict,
                  profile: profile,
                );
            if (!built) {
              if (!buildEngine) {
                progress.fail(
                  'Engine $mode: no prebuilt — source build required',
                );
              }
              anyBuildNeeded = true;
            }
          case EngineFetchStatus.failed:
            progress.fail('Engine $mode: ${result.message}');
            anyFailed = true;
        }
      }
    } finally {
      engine.close();
    }

    if (anyFailed) return ExitCode.software.code;
    if (anyBuildNeeded) {
      _logger
        ..info('')
        ..warn(
          buildEngine
              ? 'One or more modes could not be source-built (see above).'
              : 'One or more modes have no published prebuilt. Re-run with '
                    '--build-engine to build from source, or use '
                    'meta-flutter/flutter-engine.',
        );
      return ExitCode.unavailable.code;
    }
    return ExitCode.success.code;
  }

  /// Attempt a source build for one [mode]. Returns true when the artifact is
  /// now present (built or cached); completes/fails [progress] accordingly.
  Future<bool> _tryBuild({
    required HostInfo host,
    required Workspace workspace,
    required String commit,
    required String arch,
    required String mode,
    required Progress progress,
    required bool verifyAbi,
    required bool inContainer,
    required bool offline,
    required bool strict,
    required ToolchainProfile profile,
  }) async {
    final env = resolveExecEnv(
      host,
      image: _builderImage(),
      inContainer: inContainer,
    );
    if (env is ContainerExec) {
      return _buildInContainer(
        env: env,
        workspace: workspace,
        commit: commit,
        arch: arch,
        mode: mode,
        progress: progress,
        offline: offline,
        strict: strict,
        profile: profile,
      );
    }

    final build = _engineBuild ?? _defaultBuild(workspace);
    final result = await build(
      commit: commit,
      arch: arch,
      mode: mode,
      profile: profile,
      offline: offline,
      strict: strict,
    );
    switch (result.status) {
      case EngineBuildStatus.cached:
        progress.complete(
          'Engine $mode (cached build) → ${result.storeRoot?.path}',
        );
        return true;
      case EngineBuildStatus.built:
        if (verifyAbi && result.storeRoot != null) {
          final violations = await _verifyAbi(result.storeRoot!, arch, profile);
          if (violations.isNotEmpty) {
            progress.fail('Engine $mode: ABI gate failed');
            for (final v in violations) {
              _logger.err(' $v');
            }
            return false;
          }
        }
        progress.complete(
          'Engine $mode built from source → ${result.storeRoot?.path}',
        );
        return true;
      case EngineBuildStatus.unsupported:
      case EngineBuildStatus.failed:
        progress.fail('Engine $mode: ${result.message ?? "build failed"}');
        return false;
    }
  }

  /// Re-enter emb inside the builder container on a non-Linux / non-x86_64
  /// host. Returns true when the container build succeeds.
  Future<bool> _buildInContainer({
    required ContainerExec env,
    required Workspace workspace,
    required String commit,
    required String arch,
    required String mode,
    required Progress progress,
    required bool offline,
    required bool strict,
    required ToolchainProfile profile,
  }) async {
    progress.update('Engine $mode: building in ${env.image} (${env.reason})');
    final cache = ensureCacheDir();
    final launcher =
        _containerLauncher ?? ContainerLauncher(tool: _containerTool());
    final code = await launcher.run(
      image: env.image,
      embArgs: [
        'engine',
        '--build-engine',
        '--commit',
        commit,
        '--arch',
        arch,
        '--mode',
        mode,
        '--libc',
        profile.libc.token,
        if (profile.sysrootId != null) ...['--sysroot-id', profile.sysrootId!],
        if (strict) '--offline-strict' else if (offline) '--offline',
        '-w',
        workspace.root.path,
      ],
      mounts: [Mount(workspace.root.path), Mount(cache.path)],
      workdir: workspace.root.path,
    );
    if (code == 0) {
      progress.complete('Engine $mode built in ${env.image}');
      return true;
    }
    progress.fail('Engine $mode: container build failed (exit $code)');
    return false;
  }

  EngineBuildFn _defaultBuild(Workspace workspace) {
    final builder = EngineBuilder(
      store: Store(ensureCacheDir()),
      buildScript: _resolveBuildScript(),
    );
    return builder.build;
  }

  File _resolveBuildScript() {
    final override = Platform.environment['EMB_ENGINE_BUILD_SCRIPT'];
    return File(override ?? p.join('tool', 'engine', 'build-engine.sh'));
  }

  String _containerTool() =>
      Platform.environment['EMB_CONTAINER_TOOL'] ?? 'docker';

  String _builderImage() =>
      Platform.environment['EMB_ENGINE_BUILDER_IMAGE'] ??
      'ghcr.io/meta-flutter/emb-engine-builder:latest';

  Future<List<AbiViolation>> _verifyAbi(
    Directory root,
    String arch,
    ToolchainProfile profile,
  ) async {
    final so = _findFile(root, 'libflutter_engine.so');
    if (so == null) return const [];
    return EngineAbiGate().verify(so, profile: profile, arch: arch);
  }

  File? _findFile(Directory dir, String name) {
    for (final entry in dir.listSync(recursive: true, followLinks: false)) {
      if (entry is File && p.basename(entry.path) == name) return entry;
    }
    return null;
  }
}
