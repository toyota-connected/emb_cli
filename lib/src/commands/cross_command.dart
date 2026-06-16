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
/// per-backend configure/build (Phase D) hangs off the resolved profile.
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
      _logger.err('Usage: emb cross <package-dir> [--prepare]');
      return ExitCode.usage.code;
    }

    final pkgDir = Directory(args.rest.first);
    final manifest = _loader.loadPackageDir(pkgDir);
    if (manifest == null) {
      _logger.err('No emb manifest in ${pkgDir.path}.');
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

    // Provider-declared preflight (qemu-static for arm-gnu apt chroot, etc.).
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

  Future<List<String>> _missingTools(List<String> tools) async {
    final missing = <String>[];
    for (final t in tools) {
      final r = await Process.run('which', [t]);
      if (r.exitCode != 0) missing.add(t);
    }
    return missing;
  }
}
