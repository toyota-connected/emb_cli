import 'dart:io';

import 'package:emb_cli/src/cache/store.dart';
import 'package:emb_cli/src/engine/engine_builder.dart';

/// Whether the host can create a rootless network namespace.
typedef IsolationCheck = Future<bool> Function();

/// The result of certifying an engine offline build closure.
class EngineProbeResult {
  const EngineProbeResult({
    required this.commit,
    required this.closureReady,
    required this.ok,
    this.isolationOk,
  });

  final String commit;

  /// The `engine-src/<commit>` closure is materialised in the store.
  final bool closureReady;

  /// Network isolation availability, or null when not checked (non-strict).
  final bool? isolationOk;

  /// The closure is ready and (under strict) isolation is available.
  final bool ok;

  Map<String, Object?> toJson() => {
    'commit': commit,
    'closure_ready': closureReady,
    'isolation_ok': isolationOk,
    'ok': ok,
  };
}

/// Certifies that an engine offline build can run for a commit without touching
/// the network: the source closure is present, and (under strict) a rootless
/// network namespace is available. No build runs — a seconds-scale CI gate to
/// run after `emb engine fetch`.
class EngineOfflineProbe {
  EngineOfflineProbe({required Store store, IsolationCheck? isolationAvailable})
    : _store = store,
      _isolation = isolationAvailable ?? _defaultIsolation;

  final Store _store;
  final IsolationCheck _isolation;

  static Future<bool> _defaultIsolation() async {
    try {
      final r = await Process.run('unshare', [
        '--net',
        '--map-root-user',
        'true',
      ]);
      return r.exitCode == 0;
    } on ProcessException {
      return false;
    }
  }

  Future<EngineProbeResult> probe({
    required String commit,
    bool strict = false,
  }) async {
    final closureReady = _store
        .rootOf(EngineBuilder.srcKind, commit)
        .existsSync();
    final isolationOk = strict ? await _isolation() : null;
    final ok = closureReady && (!strict || (isolationOk ?? false));
    return EngineProbeResult(
      commit: commit,
      closureReady: closureReady,
      isolationOk: isolationOk,
      ok: ok,
    );
  }
}
