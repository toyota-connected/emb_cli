import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:emb_cli/src/aot/aot_builder.dart';
import 'package:emb_cli/src/cache/cache_dir.dart';
import 'package:emb_cli/src/commands/positional_args.dart';
import 'package:emb_cli/src/exec/container_reentry.dart';
import 'package:emb_cli/src/host/host_info.dart';
import 'package:emb_cli/src/workspace/workspace.dart';
import 'package:mason_logger/mason_logger.dart';

/// {@template aot_command}
/// `emb aot` — build release/profile AOT app images (`libapp.so.<mode>`) for a
/// Flutter app, using the workspace Flutter SDK and engine artifacts.
/// {@endtemplate}
class AotCommand extends Command<int> {
  /// {@macro aot_command}
  AotCommand({
    required Logger logger,
    HostInfo? host,
    AotBuilder Function(Workspace ws, HostInfo host, String? glibcSysroot)?
    builderFactory,
    ContainerReentry? reentry,
  }) : _logger = logger,
       _host = host,
       _reentry = reentry,
       _builderFactory =
           builderFactory ??
           ((ws, host, sysroot) =>
               AotBuilder(ws, host: host, glibcSysroot: sysroot)) {
    argParser
      ..addOption(
        'app-path',
        abbr: 'a',
        help: 'Path to the Flutter application to build.',
        mandatory: true,
      )
      ..addOption(
        'workspace',
        abbr: 'w',
        help: r'Workspace root (defaults to $FLUTTER_WORKSPACE or cwd).',
      )
      ..addMultiOption(
        'mode',
        abbr: 'm',
        help: 'Runtime modes to build.',
        allowed: const ['release', 'profile'],
        defaultsTo: const ['release'],
      )
      ..addOption(
        'arch',
        help:
            'Target arch for the engine gen_snapshot (defaults to host). '
            'Use e.g. arm64 to cross-build for a Raspberry Pi.',
      )
      ..addOption(
        'gen-snapshot',
        help: 'Explicit gen_snapshot path (overrides resolution).',
      )
      ..addOption(
        'glibc-sysroot',
        help:
            'Directory with ld-linux + libc to run gen_snapshot under '
            "(defaults to the artifact's bundled clang_x64/lib64).",
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
  final ContainerReentry? _reentry;
  final AotBuilder Function(Workspace ws, HostInfo host, String? glibcSysroot)
  _builderFactory;

  @override
  String get description =>
      'Build release/profile AOT images (libapp.so) for a Flutter app.';

  @override
  String get name => 'aot';

  @override
  Future<int> run() async {
    rejectPositionals(this);
    final args = argResults!;
    final host = _host ?? HostInfo.detect();
    final workspace = Workspace.resolve(override: args['workspace'] as String?);
    final appPath = args['app-path'] as String;
    final arch = args['arch'] as String?;

    if (!Directory(appPath).existsSync()) {
      _logger.err('App path not found: $appPath');
      return ExitCode.usage.code;
    }

    // The AOT step runs the Linux-x86_64 gen_snapshot; on a non-Linux/non-x86_64
    // host, route through the runtime container.
    final genSnapshot = args['gen-snapshot'] as String?;
    final glibcSysroot = args['glibc-sysroot'] as String?;
    final reentry = _reentry ?? ContainerReentry(host: host);
    final routed = await reentry.maybeRun(
      forceNative: args['exec-native'] as bool,
      workdir: workspace.root.path,
      mounts: ContainerReentry.mountsFor([
        workspace.root.path,
        Directory(appPath).absolute.path,
        ensureCacheDir().path,
        if (genSnapshot != null) File(genSnapshot).parent.path,
        if (glibcSysroot != null) glibcSysroot,
      ]),
      embArgs: [
        'aot',
        '--app-path',
        Directory(appPath).absolute.path,
        '-w',
        workspace.root.path,
        for (final m in args['mode'] as List<String>) ...['--mode', m],
        if (arch != null) ...['--arch', arch],
        if (genSnapshot != null) ...['--gen-snapshot', genSnapshot],
        if (glibcSysroot != null) ...['--glibc-sysroot', glibcSysroot],
      ],
    );
    if (routed != null) return routed;

    final builder = _builderFactory(
      workspace,
      host,
      args['glibc-sysroot'] as String?,
    );
    final result = await builder.build(
      appPath: appPath,
      modes: args['mode'] as List<String>,
      arch: arch,
      genSnapshot: args['gen-snapshot'] as String?,
      onStep: _logger.info,
    );

    for (final m in result.modes) {
      if (m.success) {
        _logger.info(lightGreen.wrap(' ${m.mode}: ${m.output}'));
      } else {
        _logger.err(' ${m.mode}: ${m.message}');
      }
    }
    return result.success ? ExitCode.success.code : ExitCode.software.code;
  }
}
