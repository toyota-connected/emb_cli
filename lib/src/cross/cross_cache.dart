import 'dart:io';

import 'package:emb_cli/src/cache/cache_dir.dart';
import 'package:emb_cli/src/cache/oci_transport.dart';
import 'package:emb_cli/src/cache/store.dart';
import 'package:emb_cli/src/cross/process_runner.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:path/path.dart' as p;

/// A content-addressed store entry to sync: its `kind` (`sysroot-base`,
/// `toolchain`) and `key`. A provider names the ones a build can fetch before
/// resolving via `cacheSelectors()`.
typedef CacheSelector = ({String kind, String key});

/// Syncs a provider's shared, content-addressed cross artifacts (the sysroot
/// base and toolchain) with an OCI registry, so a cross build resolves them as
/// store cache hits instead of re-downloading and re-extracting the multi-GB
/// distro image + toolchain on every run (the slow, root-only path that fails
/// in a non-privileged CI container).
///
/// Each artifact is keyed independently of the augment set, so one pushed blob
/// serves every target / CPU / augment variation that shares it. Both
/// operations are best-effort: a miss, an unreachable registry, or a failed
/// push all fall back to (or leave intact) the normal local extraction, so this
/// only ever *saves* work. It is opt-in via `$EMB_CACHE_REGISTRY` — with no
/// registry there is no [CrossCache] at all (see [fromEnv]).
class CrossCache {
  CrossCache({
    required this.registry,
    required this.repo,
    required Store store,
    required OciTransport transport,
    required ProcessRunner run,
    Logger? logger,
  }) : _store = store,
       _transport = transport,
       _run = run,
       _logger = logger;

  /// Build from [environment], or null when no registry is configured (the
  /// sync is opt-in). Reuses the shared cache dir + the oras transport.
  static CrossCache? fromEnv({
    required Map<String, String> environment,
    required ProcessRunner run,
    Logger? logger,
  }) {
    final registry = environment['EMB_CACHE_REGISTRY'];
    if (registry == null || registry.isEmpty) return null;
    return CrossCache(
      registry: registry,
      repo: environment['EMB_CACHE_REPO'] ?? 'emb-cache',
      store: Store(resolveCacheDir(environment: environment), run: run),
      transport: OrasTransport(run: run),
      run: run,
      logger: logger,
    );
  }

  final String registry;
  final String repo;
  final Store _store;
  final OciTransport _transport;
  final ProcessRunner _run;
  final Logger? _logger;

  /// The registry reference a [selector] pushes to / pulls from.
  String refFor(CacheSelector selector) =>
      cacheRef(registry, repo, selector.kind, selector.key);

  /// Populate the local store with each [selectors] entry from the registry.
  /// A cache hit (already staged locally) never touches the network; a registry
  /// miss or transport error leaves the normal local resolution to produce it.
  Future<void> pull(Iterable<CacheSelector> selectors) async {
    for (final s in selectors) {
      await _pullOne(s);
    }
  }

  /// Push each locally-resolved [selectors] entry to the registry (skipped when
  /// the ref already exists). Call after a resolve has populated the store; a
  /// push failure is logged but does not fail the caller.
  Future<void> push(Iterable<CacheSelector> selectors) async {
    for (final s in selectors) {
      await _pushOne(s);
    }
  }

  Future<void> _pullOne(CacheSelector s) async {
    final ref = refFor(s);
    final tmp = Directory.systemTemp.createTempSync('emb_xc_pull_');
    try {
      await _store.ensure(
        kind: s.kind,
        key: s.key,
        sourceUrl: ref,
        fetch: () => _transport.pull(ref, tmp),
        stage: (blob, into) async {
          final r = await _run('tar', [
            '-xzf',
            blob.path,
            '-C',
            into.path,
          ], output: ProcessOutputMode.capture);
          if (r.exitCode != 0) {
            throw OciTransportException('untar $ref failed: ${r.stderr}');
          }
        },
      );
      _logger?.detail('${s.kind} pulled from $ref');
    } on Exception catch (e) {
      // Not published yet, registry unreachable, or oras absent: fall back to
      // the local resolution path. Never fail the build over a cache miss.
      _logger?.detail('${s.kind} not pulled ($ref): $e');
    } finally {
      tmp.deleteSync(recursive: true);
    }
  }

  Future<void> _pushOne(CacheSelector s) async {
    final ref = refFor(s);
    try {
      if (await _transport.exists(ref)) {
        _logger?.detail('${s.kind} already in registry ($ref)');
        return;
      }
      final root = _store.rootOf(s.kind, s.key);
      if (!root.existsSync()) {
        _logger?.detail('no local ${s.kind} to push ($ref)');
        return;
      }
      final tmp = Directory.systemTemp.createTempSync('emb_xc_push_');
      try {
        final layer = File(
          p.join(tmp.path, '${cacheTag(s.kind, s.key)}.tar.gz'),
        );
        final tar = await _run('tar', [
          '-czf',
          layer.path,
          '-C',
          root.path,
          '.',
        ], output: ProcessOutputMode.capture);
        if (tar.exitCode != 0) {
          _logger?.warn('${s.kind} tar failed ($ref): ${tar.stderr}');
          return;
        }
        await _transport.push(
          ref,
          layer,
          annotations: {
            'org.opencontainers.image.title': p.basename(layer.path),
            'dev.emb.cache.kind': s.kind,
            'dev.emb.cache.key': s.key,
          },
        );
        _logger?.detail('${s.kind} pushed to $ref');
      } finally {
        tmp.deleteSync(recursive: true);
      }
    } on Exception catch (e) {
      _logger?.warn('${s.kind} push failed ($ref): $e');
    }
  }
}
