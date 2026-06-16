import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:emb_cli/src/cross/cross_profile.dart';
import 'package:emb_cli/src/cross/cross_provider.dart';
import 'package:emb_cli/src/cross/cross_target.dart';
import 'package:emb_cli/src/cross/overlay_builder.dart';
import 'package:emb_cli/src/host/host_info.dart';
import 'package:emb_cli/src/manifest/manifest_loader.dart';
import 'package:emb_cli/src/workspace/workspace.dart';
import 'package:mason_logger/mason_logger.dart';

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
  }) : _logger = logger,
       _host = host,
       _loader = loader {
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
      );
  }

  final Logger _logger;
  final HostInfo? _host;
  final ManifestLoader _loader;

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

    // Accept either a package directory (with emb.yaml) or an explicit manifest
    // file (e.g. examples/cross/pi5.emb.yaml).
    final inputPath = args.rest.first;
    final manifest =
        FileSystemEntity.typeSync(inputPath) == FileSystemEntityType.file
        ? _loader.loadManifestFile(File(inputPath))
        : _loader.loadPackageDir(Directory(inputPath));
    if (manifest == null) {
      _logger.err('No emb manifest at $inputPath.');
      return ExitCode.usage.code;
    }
    final crossMap = manifest.raw['cross'];
    if (crossMap is! Map) {
      _logger.err('${manifest.id} has no cross: block.');
      return ExitCode.usage.code;
    }

    final CrossTarget target;
    try {
      target = CrossTarget.fromMap(Map<dynamic, dynamic>.from(crossMap));
      // fromMap throws ArgumentError on an unknown provider token.
      // ignore: avoid_catching_errors
    } on ArgumentError catch (e) {
      _logger.err('Invalid cross: block — ${e.message}');
      return ExitCode.usage.code;
    }

    final host = _host ?? HostInfo.detect();
    final workspace = Workspace.resolve(override: args['workspace'] as String?);
    final provider = CrossProvider.forTarget(
      target,
      workspace: workspace,
      host: host,
    );

    // --dry-run: report the plan without any download / mount / ssh side
    // effects, so every target validates on any host.
    if (args['dry-run'] == true) {
      await _plan(provider, target, host);
      return ExitCode.success.code;
    }

    // Provider-declared preflight (tar/xz/rsync for arm-gnu, etc.).
    final missing = await _missingTools(provider.preflightTools);
    if (missing.isNotEmpty) {
      _logger.err(
        'Missing host tools for ${provider.name}: ${missing.join(", ")}',
      );
      return ExitCode.unavailable.code;
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
    return ExitCode.success.code;
  }

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
  }

  Future<List<String>> _missingTools(List<String> tools) async {
    final missing = <String>[];
    for (final t in tools) {
      final r = await Process.run('which', [t]);
      if (r.exitCode != 0) missing.add(t);
    }
    return missing;
  }
}
