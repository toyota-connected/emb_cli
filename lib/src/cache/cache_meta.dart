import 'dart:convert';
import 'dart:io';

/// Sidecar metadata for a CAS blob or a store entry, serialized as `meta.json`.
///
/// [complete] is written **last**, after the atomic rename, so a crash
/// mid-extract leaves `complete:false` (or no meta) and the entry is treated as
/// absent and re-staged. Anything security-relevant (the sha) is re-derivable
/// from the bytes; the meta is advisory.
class CacheMeta {
  /// Creates metadata. Use [nowIso] for the timestamps.
  const CacheMeta({
    required this.kind,
    required this.key,
    required this.created,
    required this.lastUsed,
    required this.sizeBytes,
    required this.complete,
    this.sourceUrl,
    this.sourceSha,
    this.schema = 1,
  });

  /// Parse from JSON; missing fields fall back to safe defaults.
  factory CacheMeta.fromJson(Map<String, Object?> j) {
    final src = (j['source'] as Map?)?.cast<String, Object?>() ?? const {};
    return CacheMeta(
      schema: (j['schema'] as num?)?.toInt() ?? 1,
      kind: j['kind'] as String? ?? '',
      key: j['key'] as String? ?? '',
      sourceUrl: src['url'] as String?,
      sourceSha: src['sha256'] as String?,
      created: j['created'] as String? ?? '',
      lastUsed: j['lastUsed'] as String? ?? '',
      sizeBytes: (j['sizeBytes'] as num?)?.toInt() ?? 0,
      complete: j['complete'] as bool? ?? false,
    );
  }

  /// Schema version of the `data` layout; bump on a breaking change.
  final int schema;

  /// Entry kind — `toolchain`, `engine`, or `cas`.
  final String kind;

  /// The store key (or the blob sha for CAS entries).
  final String key;

  /// Source download URL, when known.
  final String? sourceUrl;

  /// Source blob sha256, when known.
  final String? sourceSha;

  /// ISO-8601 UTC creation time.
  final String created;

  /// ISO-8601 UTC time of the last resolve that consumed this entry.
  final String lastUsed;

  /// Total size of the entry's bytes (blob size, or extracted tree size).
  final int sizeBytes;

  /// Whether the entry finished staging. Only complete entries are usable.
  final bool complete;

  /// A copy with [lastUsed] set to [now].
  CacheMeta touch(String now) => CacheMeta(
    kind: kind,
    key: key,
    created: created,
    lastUsed: now,
    sizeBytes: sizeBytes,
    complete: complete,
    sourceUrl: sourceUrl,
    sourceSha: sourceSha,
    schema: schema,
  );

  /// JSON form written to `meta.json`.
  Map<String, Object?> toJson() => {
    'schema': schema,
    'kind': kind,
    'key': key,
    'source': {
      if (sourceUrl != null) 'url': sourceUrl,
      if (sourceSha != null) 'sha256': sourceSha,
    },
    'created': created,
    'lastUsed': lastUsed,
    'sizeBytes': sizeBytes,
    'complete': complete,
  };

  /// Read [file], or null if absent or unparseable.
  static CacheMeta? read(File file) {
    if (!file.existsSync()) return null;
    try {
      final j = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
      return CacheMeta.fromJson(j);
    } on Object {
      return null;
    }
  }

  /// Write pretty JSON to [file], creating parents.
  void write(File file) {
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(toJson()),
    );
  }
}

/// The current time as an ISO-8601 UTC string, for [CacheMeta] timestamps.
String nowIso() => DateTime.now().toUtc().toIso8601String();
