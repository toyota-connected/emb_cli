import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:emb_cli/src/cache/cache_lock.dart';
import 'package:emb_cli/src/cache/cache_meta.dart';
import 'package:emb_cli/src/cross/cross_keys.dart';
import 'package:path/path.dart' as p;

/// A content-addressed store failure (download or sha mismatch).
class CasException implements Exception {
  /// Creates the exception with a human-readable [message].
  CasException(this.message);

  /// The failure detail.
  final String message;
  @override
  String toString() => 'CasException: $message';
}

/// Content-addressed store of raw downloaded blobs under
/// `<root>/cas/sha256/<ab>/<sha>/blob`, keyed by sha256 of the bytes.
///
/// Because the key is the content hash, a hit is self-verifying and needs no
/// re-download-and-compare. The same URL served from a mirror that hashes
/// identically is a hit, not drift.
class Cas {
  /// Roots the CAS at [root]; [httpClient] is injectable for tests. When
  /// [offline] is set, [ensure] never touches the network: a blob already in
  /// the cache is returned, and anything else fails instead of downloading.
  Cas(this.root, {HttpClient? httpClient, this.offline = false})
    : _http = httpClient ?? HttpClient();

  /// The cache root (holds `cas/`, `tmp/`).
  final Directory root;

  /// When true, a cache miss is an error rather than a download.
  final bool offline;

  final HttpClient _http;

  Directory get _casDir => Directory(p.join(root.path, 'cas', 'sha256'));
  Directory get _tmpDir => Directory(p.join(root.path, 'tmp'));

  /// The blob file for [sha] (2-char shard), whether or not it exists.
  File blobFor(String sha) =>
      File(p.join(_casDir.path, sha.substring(0, 2), sha, 'blob'));

  /// Ensure the blob for [url] is present, and return it. When [expectedSha] is
  /// given the downloaded bytes are verified against it and a mismatch throws
  /// [CasException]; the download itself is serialized per URL by a flock.
  Future<File> ensure(String url, {String? expectedSha}) async {
    if (expectedSha != null && blobFor(expectedSha).existsSync()) {
      return blobFor(expectedSha);
    }
    if (offline) {
      throw CasException(
        'offline: required artifact not cached: $url'
        '${expectedSha != null ? " (sha256 $expectedSha)" : ""} — '
        'fetch it online before an offline build',
      );
    }
    final lock = File(
      p.join(root.path, 'cas', 'locks', '${contentHash([url])}.lock'),
    );
    return withFileLock(lock, () async {
      // Re-check under the lock: another job may have just finished it.
      if (expectedSha != null && blobFor(expectedSha).existsSync()) {
        return blobFor(expectedSha);
      }
      _tmpDir.createSync(recursive: true);
      final part = File(
        p.join(_tmpDir.path, '${contentHash([url])}.$pid.part'),
      );
      _safeDelete(part);
      if (!await _download(url, part)) {
        _safeDelete(part);
        throw CasException('download failed: $url');
      }
      final sha = await _sha256OfFile(part);
      if (expectedSha != null && sha != expectedSha) {
        _safeDelete(part);
        throw CasException(
          'sha mismatch for $url: expected $expectedSha, got $sha',
        );
      }
      final blob = blobFor(sha);
      if (blob.existsSync()) {
        _safeDelete(part);
        return blob;
      }
      blob.parent.createSync(recursive: true);
      part.renameSync(blob.path);
      CacheMeta(
        kind: 'cas',
        key: sha,
        sourceUrl: url,
        sourceSha: sha,
        created: nowIso(),
        lastUsed: nowIso(),
        sizeBytes: blob.lengthSync(),
        complete: true,
      ).write(File(p.join(blob.parent.path, 'meta.json')));
      return blob;
    });
  }

  /// Close the owned [HttpClient].
  void close() => _http.close(force: true);

  /// HTTP GET [url] to [dest] (follows redirects). Returns false on non-200.
  Future<bool> _download(String url, File dest) async {
    try {
      final req = await _http.getUrl(Uri.parse(url));
      req.followRedirects = true;
      final resp = await req.close();
      if (resp.statusCode != 200) {
        await resp.drain<void>();
        return false;
      }
      await resp.pipe(dest.openWrite());
      return true;
    } on Object {
      return false;
    }
  }

  /// Streaming sha256 of [f] — chunked so a multi-GB blob is never held in
  /// memory.
  Future<String> _sha256OfFile(File f) async {
    late Digest digest;
    final input = sha256.startChunkedConversion(
      ChunkedConversionSink<Digest>.withCallback((ds) => digest = ds.single),
    );
    await for (final chunk in f.openRead()) {
      input.add(chunk);
    }
    input.close();
    return digest.toString();
  }

  void _safeDelete(File f) {
    if (f.existsSync()) f.deleteSync();
  }
}
