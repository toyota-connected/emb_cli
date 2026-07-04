import 'dart:io';

import 'package:emb_cli/src/cross/emb_lock.dart';
import 'package:emb_cli/src/cross/process_runner.dart';
import 'package:emb_cli/src/host/preflight.dart';
import 'package:emb_cli/src/version.dart';
import 'package:emb_cli/src/workspace/workspace.dart';
import 'package:mason_logger/mason_logger.dart';

/// Reconciles a project's `emb.lock` against freshly resolved facts, shared by
/// every command that resolves a cross target (`emb cross`, `emb fetch`). Keeps
/// the reconcile, self-pin capture, and drift reporting in one place so the two
/// entry points can never diverge on lock behavior.
class LockSync {
  LockSync({
    required Logger logger,
    required ProcessRunner runProcess,
    required Preflight preflight,
  }) : _logger = logger,
       _runProcess = runProcess,
       _preflight = preflight;

  final Logger _logger;
  final ProcessRunner _runProcess;
  final Preflight _preflight;

  /// Reconcile `<projectRoot>/emb.lock` with the freshly [resolved] facts.
  ///
  /// Auto-creates the entry when absent (first resolve, pub-style), verifies
  /// and fails on drift when present, or rewrites it under [updateLock]. The
  /// root [env] self-pins are attached when (re)writing. Returns false only on
  /// a verification failure (the caller then exits).
  bool sync({
    required String projectRoot,
    required String target,
    required LockedTarget resolved,
    required LockEnv env,
    required bool updateLock,
    required bool verify,
  }) {
    final lockFile = File('$projectRoot/emb.lock');
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

  /// The host tool versions this resolve ran with, for the lock's root `env`
  /// self-pins. Each is best-effort: a missing SDK/tool records null rather
  /// than failing the build.
  Future<LockEnv> selfPins(Workspace workspace) async {
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
}
