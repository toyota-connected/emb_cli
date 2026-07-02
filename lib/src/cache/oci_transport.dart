import 'dart:io';

import 'package:emb_cli/src/cross/cross_keys.dart' show contentHash;
import 'package:emb_cli/src/cross/process_runner.dart';

/// Media type for a store-entry tree packaged as one gzip tar layer.
const cacheLayerMediaType = 'application/vnd.emb.cache.layer.v1.tar+gzip';

/// The OCI tag for a store entry `(kind, key)`: `<kind>-<key>`, sanitized to
/// the tag charset (`[A-Za-z0-9_.-]`) and kept within the 128-char limit. A
/// too-long tag is truncated and suffixed with a short content hash so it stays
/// unique and deterministic (same inputs → same tag on push and pull).
String cacheTag(String kind, String key) {
  final raw = '$kind-$key';
  final safe = raw.replaceAll(RegExp('[^A-Za-z0-9_.-]'), '-');
  if (safe.length <= 128) return safe;
  return '${safe.substring(0, 115)}-${contentHash([raw])}';
}

/// The full OCI reference for a store entry: `<registry>/<repo>:<tag>`.
String cacheRef(String registry, String repo, String kind, String key) =>
    '$registry/$repo:${cacheTag(kind, key)}';

/// Raised when the underlying transport CLI fails.
class OciTransportException implements Exception {
  /// Creates an exception with a human [message].
  OciTransportException(this.message);

  /// The failure detail (typically the CLI's stderr tail).
  final String message;

  @override
  String toString() => message;
}

/// A remote transport for store-entry layers, abstracted from the concrete CLI
/// so the `emb cache push`/`pull` commands don't depend on it directly. The
/// only implementation today is [OrasTransport]; a skopeo/HTTP backend could
/// slot in behind the same interface.
abstract class OciTransport {
  /// Whether [ref] already exists in the registry.
  Future<bool> exists(String ref);

  /// Push the local [layer] tarball to [ref], attaching [annotations].
  Future<void> push(String ref, File layer, {Map<String, String> annotations});

  /// Pull [ref]'s layer into [into] and return the downloaded tar file.
  Future<File> pull(String ref, Directory into);

  /// The underlying CLI name (for preflight / diagnostics).
  String get tool;
}

/// An [OciTransport] backed by the `oras` CLI — a single static binary
/// available on Linux/macOS/Windows with no daemon, purpose-built for OCI
/// artifacts. Authentication is delegated to a prior `oras login` (it reuses
/// `~/.docker/config.json`), matching the registry-agnostic `--publish` path.
class OrasTransport implements OciTransport {
  /// Creates a transport running [exe] through [run].
  OrasTransport({ProcessRunner run = defaultProcessRunner, this.exe = 'oras'})
    : _run = run;

  final ProcessRunner _run;

  /// The CLI executable (default `oras`).
  final String exe;

  @override
  String get tool => exe;

  @override
  Future<bool> exists(String ref) async {
    final r = await _run(exe, [
      'manifest',
      'fetch',
      ref,
    ], output: ProcessOutputMode.capture);
    return r.exitCode == 0;
  }

  @override
  Future<void> push(
    String ref,
    File layer, {
    Map<String, String> annotations = const {},
  }) async {
    final r = await _run(
      exe,
      [
        'push',
        ref,
        '${layer.path}:$cacheLayerMediaType',
        for (final e in annotations.entries) ...[
          '--annotation',
          '${e.key}=${e.value}',
        ],
      ],
      output: ProcessOutputMode.stream,
      label: 'oras:push',
    );
    if (r.exitCode != 0) {
      throw OciTransportException('oras push $ref failed: ${r.stderr}');
    }
  }

  @override
  Future<File> pull(String ref, Directory into) async {
    into.createSync(recursive: true);
    final r = await _run(
      exe,
      ['pull', ref, '-o', into.path],
      output: ProcessOutputMode.stream,
      label: 'oras:pull',
    );
    if (r.exitCode != 0) {
      throw OciTransportException('oras pull $ref failed: ${r.stderr}');
    }
    // oras restores the layer under its original filename; find the tarball.
    final tars = into
        .listSync()
        .whereType<File>()
        .where((f) => RegExp(r'\.t(ar\.gz|gz|ar)$').hasMatch(f.path))
        .toList();
    if (tars.isEmpty) {
      throw OciTransportException(
        'oras pull $ref produced no layer file in ${into.path}',
      );
    }
    return tars.first;
  }
}
