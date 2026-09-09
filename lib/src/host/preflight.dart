import 'dart:io';

import 'package:emb_cli/src/host/host_info.dart';
import 'package:emb_cli/src/host/install_hint.dart';
import 'package:emb_cli/src/pkg/host_provisioner.dart';
import 'package:emb_cli/src/step_reporter.dart';
import 'package:mason_logger/mason_logger.dart';

/// Probes whether a host [tool] is available on `PATH`. Injectable so callers
/// (and tests) can substitute the default `which` shell-out.
typedef ToolProbe = Future<bool> Function(String tool);

/// The default [ToolProbe]: a tool is present when `which <tool>` exits 0.
Future<bool> whichProbe(String tool) async =>
    (await Process.run('which', [tool])).exitCode == 0;

/// Builds the [HostProvisioner] for a host. Injectable so tests can supply a
/// fake instead of talking to the real package backend.
typedef ProvisionerFactory =
    HostProvisioner Function(HostInfo host, {bool interactive});

/// Host-tool preflight: which required tools are missing, how to install them
/// (via the running package backend or a static fallback hint), and an opt-in
/// auto-install. Shared by `emb cross` (build/plan preflight) and `emb doctor
/// --target`.
class Preflight {
  /// Creates a preflight helper that logs through [Logger]. [probe] defaults to
  /// a `which` shell-out; inject a fake in tests to avoid real binaries.
  Preflight(
    this._logger, {
    ToolProbe probe = whichProbe,
    ProvisionerFactory? provisionerFactory,
  }) : _probe = probe,
       _provisionerFor = provisionerFactory ?? HostProvisioner.forHost;

  final Logger _logger;
  final ToolProbe _probe;
  final ProvisionerFactory _provisionerFor;

  StepReporter get _steps => StepReporter(_logger);

  /// The subset of [tools] not found on `PATH` (in input order).
  Future<List<String>> missingTools(List<String> tools) async {
    final missing = <String>[];
    for (final t in tools) {
      if (!await _probe(t)) missing.add(t);
    }
    return missing;
  }

  /// The subset of [packages] the host package backend reports as NOT
  /// installed, or null when no backend can answer.
  ///
  /// Unlike [missingTools] this asks the package backend rather than probing
  /// `PATH`, because a `-dev` package ships headers and a `.pc` file and no
  /// executable — `which` can never see it. Null means "could not determine"
  /// (no backend reachable, or it errored); callers should proceed rather than
  /// block a build on a check the host cannot answer.
  Future<List<String>?> missingPackages(
    HostInfo host,
    List<String> packages,
  ) async {
    if (packages.isEmpty) return const [];
    HostProvisioner? provisioner;
    try {
      provisioner = _provisionerFor(host);
      // ignore: avoid_catching_errors
    } on UnsupportedError {
      return null; // platform backend not compiled into this build
    }
    try {
      if (!await provisioner.isAvailable()) return null;
      final missing = await provisioner.missing(packages.toSet());
      // Preserve the caller's order so messages read predictably.
      return [
        for (final p in packages)
          if (missing.contains(p)) p,
      ];
    } on Exception {
      return null;
    } finally {
      await provisioner.dispose();
    }
  }

  /// Install the missing preflight [tools] via [HostProvisioner] (opt-in, with
  /// `--install-deps`). Returns true only when the tools are present after.
  /// Falls back to the manual hint when no backend is reachable.
  ///
  /// [interactive] governs whether the backend may prompt for authorization.
  ///
  /// [what] names the kind of thing being installed, for the progress line.
  /// [verifyOnPath] confirms the result with `which`; pass false for package
  /// names that ship no executable, which are re-checked via the backend.
  Future<bool> install(
    HostInfo host,
    String providerName,
    List<String> tools, {
    bool interactive = true,
    String what = 'host tools',
    bool verifyOnPath = true,
  }) async {
    HostProvisioner? provisioner;
    try {
      provisioner = _provisionerFor(host, interactive: interactive);
      // ignore: avoid_catching_errors
    } on UnsupportedError {
      provisioner = null;
    }
    if (provisioner == null || !await provisioner.isAvailable()) {
      await provisioner?.dispose();
      _logger.err(
        'Cannot auto-install $what (no package backend). Install manually:',
      );
      await logInstallHint(host, tools);
      return false;
    }

    final progress = _steps.start(
      'Installing $what for $providerName: ${tools.join(", ")}',
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

    // The backend reported success; confirm it actually took. A -dev package
    // puts nothing on PATH, so re-ask the backend instead of probing `which`;
    // a null answer there means "cannot tell", which is not a failure.
    final stillMissing = verifyOnPath
        ? await missingTools(tools)
        : await missingPackages(host, tools) ?? const <String>[];
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
  Future<void> logInstallHint(HostInfo host, List<String> tools) async {
    HostProvisioner? provisioner;
    try {
      provisioner = _provisionerFor(host);
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
