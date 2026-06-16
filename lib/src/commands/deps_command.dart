import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:emb_cli/src/deps/dependency_resolver.dart';
import 'package:emb_cli/src/host/host_info.dart';
import 'package:emb_cli/src/manifest/emb_manifest.dart';
import 'package:emb_cli/src/manifest/manifest_loader.dart';
import 'package:emb_cli/src/pkg/host_provisioner.dart';
import 'package:mason_logger/mason_logger.dart';

/// {@template deps_command}
/// `emb deps` — coalesce host dependencies across all manifests, filter to
/// what this host needs and is missing, then install them in one transaction.
/// {@endtemplate}
class DepsCommand extends Command<int> {
  /// {@macro deps_command}
  DepsCommand({
    required Logger logger,
    HostInfo? host,
    HostProvisioner Function(HostInfo host)? provisionerFactory,
    ManifestLoader loader = const ManifestLoader(),
  }) : _logger = logger,
       _host = host,
       _loader = loader,
       _provisionerFactory = provisionerFactory ?? HostProvisioner.forHost {
    argParser
      ..addMultiOption(
        'config',
        abbr: 'c',
        help: 'Legacy JSON config directory (repeatable).',
        defaultsTo: const ['configs'],
      )
      ..addMultiOption(
        'packages',
        abbr: 'p',
        help:
            'Directory to discover self-describing emb manifests '
            '(repeatable).',
      )
      ..addMultiOption(
        'enable',
        help:
            'Force-load the config with this id (overrides load: false). '
            'Repeatable; ids that match nothing are ignored.',
      )
      ..addMultiOption(
        'disable',
        help:
            'Skip the config with this id (overrides load: true). '
            'Repeatable; ids that match nothing are ignored.',
      )
      ..addFlag(
        'dry-run',
        help: 'Resolve and print the install plan without changing the system.',
        negatable: false,
      )
      ..addFlag(
        'yes',
        abbr: 'y',
        help: 'Skip the confirmation prompt (for CI).',
        negatable: false,
      );
  }

  final Logger _logger;
  final HostInfo? _host;
  final ManifestLoader _loader;
  final HostProvisioner Function(HostInfo host) _provisionerFactory;

  @override
  String get description =>
      'Coalesce, filter, and install host OS dependencies in one transaction.';

  @override
  String get name => 'deps';

  @override
  Future<int> run() async {
    final args = argResults!;
    final host = _host ?? HostInfo.detect();

    // ── Load manifests ────────────────────────────────────────────────────
    final raw = <EmbManifest>[];
    for (final dir in args['config'] as List<String>) {
      raw.addAll(_loader.loadConfigDir(Directory(dir)));
    }
    for (final dir in args['packages'] as List<String>) {
      raw.addAll(_loader.discoverPackages(Directory(dir)));
    }
    final manifests = _loader.select(
      raw,
      enable: (args['enable'] as List<String>).toSet(),
      disable: (args['disable'] as List<String>).toSet(),
    );

    if (manifests.isEmpty) {
      _logger.warn(
        'No manifests found. '
        'Pass --config <dir> and/or --packages <dir>.',
      );
      return ExitCode.success.code;
    }

    // ── Coalesce ──────────────────────────────────────────────────────────
    final resolver = DependencyResolver(host);
    final coalesced = resolver.coalesce(manifests);

    _logger
      ..info(
        'Host: ${host.os.name}/${host.machineArch} '
        '(${host.hostType} ${host.versionId})',
      )
      ..info(
        'Manifests: ${manifests.length}, '
        'contributing: ${coalesced.byComponent.length}, '
        'skipped: ${coalesced.skipped.length}',
      )
      ..info('Coalesced packages: ${coalesced.packages.length}')
      ..detail('Cache key: ${coalesced.contentHash}');

    if (coalesced.isEmpty) {
      _logger.info('No applicable host dependencies for this host.');
      return ExitCode.success.code;
    }

    final provisioner = _provisionerFactory(host);
    try {
      if (!await provisioner.isAvailable()) {
        _logger.err('Package backend "${provisioner.name}" is not available.');
        return ExitCode.unavailable.code;
      }

      // ── Dry-run ─────────────────────────────────────────────────────────
      if (args['dry-run'] as bool) {
        final plan = await provisioner.simulate(coalesced.packages.toSet());
        if (plan.toInstall.isEmpty &&
            plan.additional.isEmpty &&
            plan.unresolved.isEmpty) {
          _logger.info(
            lightGreen.wrap(
              'All ${coalesced.packages.length} dependencies '
              'already satisfied.',
            ),
          );
          return ExitCode.success.code;
        }
        if (plan.toInstall.isNotEmpty) {
          _logger.info(
            'Would install (${plan.toInstall.length}): '
            '${plan.toInstall.join(", ")}',
          );
        }
        if (plan.additional.isNotEmpty) {
          _logger.info(
            'Additional deps (${plan.additional.length}): '
            '${plan.additional.join(", ")}',
          );
        }
        if (plan.unresolved.isNotEmpty) {
          _logger.warn(
            'Unresolved (${plan.unresolved.length}): '
            '${plan.unresolved.join(", ")}',
          );
        }
        return ExitCode.success.code;
      }

      // ── Filter ──────────────────────────────────────────────────────────
      final filtered = await resolver.filter(coalesced, provisioner);
      if (filtered.isSatisfied) {
        _logger.info(
          lightGreen.wrap(
            'All ${coalesced.packages.length} dependencies already '
            'satisfied.',
          ),
        );
        return ExitCode.success.code;
      }

      _logger.info(
        'Missing (${filtered.missing.length}): '
        '${filtered.missing.join(", ")}',
      );

      if (!(args['yes'] as bool)) {
        final proceed = _logger.confirm(
          'Install ${filtered.missing.length} package(s)?',
          defaultValue: true,
        );
        if (!proceed) {
          _logger.info('Aborted.');
          return ExitCode.success.code;
        }
      }

      // ── Install (single transaction) ────────────────────────────────────
      final progress = _logger.progress(
        'Installing ${filtered.missing.length} package(s)',
      );
      final result = await provisioner.install(
        filtered.missing.toSet(),
        onProgress: (p) => progress.update(
          'Installing ${p.label}${p.percent != null ? " (${p.percent}%)" : ""}',
        ),
      );
      if (result.success) {
        progress.complete('Installed ${result.installed.length} package(s)');
        return ExitCode.success.code;
      }
      progress.fail('Install failed');
      if (result.message != null) _logger.err(result.message);
      return ExitCode.software.code;
    } finally {
      await provisioner.dispose();
    }
  }
}
