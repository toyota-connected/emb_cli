import 'dart:io';

import 'package:emb_cli/src/cache/cache_lock.dart';
import 'package:emb_cli/src/cache/cache_meta.dart';
import 'package:emb_cli/src/cross/cross_keys.dart';
import 'package:emb_cli/src/cross/process_runner.dart';
import 'package:path/path.dart' as p;

/// One extracted store entry, for `emb cache list`/`gc`.
class StoreEntry {
  /// Creates an entry descriptor.
  StoreEntry({
    required this.kind,
    required this.key,
    required this.meta,
    required this.liveRefs,
    required this.dir,
  });

  /// Entry kind (`toolchain`, `engine`).
  final String kind;

  /// Entry key (the semantic identity).
  final String key;

  /// Parsed `meta.json`, or null if missing/unparseable.
  final CacheMeta? meta;

  /// Number of live symlink backlinks pointing at this entry.
  final int liveRefs;

  /// The entry directory (`store/<kind>/<key>`).
  final Directory dir;
}

/// The result of a `gc` pass.
class GcReport {
  /// Creates a report.
  GcReport({required this.removed, required this.bytesFreed});

  /// `<kind>/<key>` of each removed entry.
  final List<String> removed;

  /// Total bytes reclaimed (or that would be, under `--dry-run`).
  final int bytesFreed;
}

/// A store of **extracted, immutable** trees under `<root>/store/<kind>/<key>/`,
/// keyed by semantic identity. Extraction is the expensive part, so entries are
/// keyed by identity (not content) and materialized into workspaces by symlink.
///
/// Immutability is by convention — nothing writes into a stored tree (overlay
/// builds install with `DESTDIR` into a private prefix). A `chmod -R a-w`
/// hardening pass is deferred to keep gc deletion simple.
class Store {
  /// Roots the store at [root]; [run] runs `tar`/`xz` (injectable for tests).
  Store(this.root, {ProcessRunner run = defaultProcessRunner}) : _run = run;

  /// The cache root (holds `store/`, `tmp/`).
  final Directory root;
  final ProcessRunner _run;

  /// The injected process runner, for callers' `stage` callbacks.
  ProcessRunner get run => _run;

  Directory get _storeDir => Directory(p.join(root.path, 'store'));
  Directory get _tmpDir => Directory(p.join(root.path, 'tmp'));

  /// The entry directory for ([kind], [key]).
  Directory entryDir(String kind, String key) =>
      Directory(p.join(_storeDir.path, kind, key));

  /// The extracted-tree root for ([kind], [key]).
  Directory rootOf(String kind, String key) =>
      Directory(p.join(entryDir(kind, key).path, 'root'));

  File _metaFile(String kind, String key) =>
      File(p.join(entryDir(kind, key).path, 'meta.json'));

  File _lockFile(String kind, String key) =>
      File(p.join(entryDir(kind, key).path, '.lock'));

  Directory _refsDir(String kind, String key) =>
      Directory(p.join(entryDir(kind, key).path, 'refs'));

  /// Ensure the extracted tree for ([kind], [key]) exists and return its root.
  ///
  /// [fetch] returns the source blob (typically `Cas.ensure`); [stage] extracts
  /// it into the provided staging dir. The stage runs under an exclusive flock;
  /// completeness + atomic rename make reads lock-free. [sourceUrl]/[sourceSha]
  /// are recorded in `meta.json`.
  Future<Directory> ensure({
    required String kind,
    required String key,
    required Future<File> Function() fetch,
    required Future<void> Function(File blob, Directory into) stage,
    String? sourceUrl,
    String? sourceSha,
  }) async {
    if (_isComplete(kind, key)) return _touch(kind, key);

    entryDir(kind, key).createSync(recursive: true);
    return withFileLock(_lockFile(kind, key), () async {
      if (_isComplete(kind, key)) return _touch(kind, key);

      // Clear any partial leftovers from a crashed prior stage.
      final target = rootOf(kind, key);
      if (target.existsSync()) target.deleteSync(recursive: true);
      final metaF = _metaFile(kind, key);
      if (metaF.existsSync()) metaF.deleteSync();

      final blob = await fetch();
      _tmpDir.createSync(recursive: true);
      final staging = Directory(
        p.join(_tmpDir.path, '$kind-${contentHash([key])}.$pid'),
      );
      if (staging.existsSync()) staging.deleteSync(recursive: true);
      staging.createSync(recursive: true);
      await stage(blob, staging);

      // Atomic publish: rename staging → root on the same filesystem.
      staging.renameSync(target.path);
      CacheMeta(
        kind: kind,
        key: key,
        sourceUrl: sourceUrl,
        sourceSha: sourceSha,
        created: nowIso(),
        lastUsed: nowIso(),
        sizeBytes: _treeSize(target),
        complete: true,
      ).write(metaF);
      return target;
    });
  }

  /// Symlink [linkPath] → the store root for ([kind], [key]) and record a
  /// backlink so gc can discover this live reference. Any existing symlink,
  /// dir, or file at [linkPath] is replaced.
  void materialize({
    required String kind,
    required String key,
    required String linkPath,
  }) {
    Directory(p.dirname(linkPath)).createSync(recursive: true);
    final type = FileSystemEntity.typeSync(linkPath, followLinks: false);
    if (type == FileSystemEntityType.link) {
      Link(linkPath).deleteSync();
    } else if (type == FileSystemEntityType.directory) {
      Directory(linkPath).deleteSync(recursive: true);
    } else if (type == FileSystemEntityType.file) {
      File(linkPath).deleteSync();
    }
    Link(linkPath).createSync(rootOf(kind, key).absolute.path);
    final refs = _refsDir(kind, key)..createSync(recursive: true);
    File(
      p.join(refs.path, contentHash([linkPath])),
    ).writeAsStringSync(linkPath);
  }

  /// Every store entry, with its live-ref count (prunes dead backlinks).
  List<StoreEntry> list() {
    final out = <StoreEntry>[];
    if (!_storeDir.existsSync()) return out;
    for (final kindDir in _storeDir.listSync().whereType<Directory>()) {
      final kind = p.basename(kindDir.path);
      for (final entry in kindDir.listSync().whereType<Directory>()) {
        final key = p.basename(entry.path);
        out.add(
          StoreEntry(
            kind: kind,
            key: key,
            meta: CacheMeta.read(_metaFile(kind, key)),
            liveRefs: _liveRefs(kind, key).length,
            dir: entry,
          ),
        );
      }
    }
    return out;
  }

  /// Remove incomplete (crash-leftover) entries and complete entries with zero
  /// live refs whose `lastUsed` is older than [safetyWindow]. Each candidate is
  /// removed under its flock so an in-progress stage is never disturbed.
  Future<GcReport> gc({
    bool dryRun = false,
    Duration safetyWindow = const Duration(days: 7),
  }) async {
    final removed = <String>[];
    var freed = 0;
    for (final e in list()) {
      freed += await withFileLock(_lockFile(e.kind, e.key), () async {
        final meta = CacheMeta.read(_metaFile(e.kind, e.key));
        final incomplete = meta == null || !meta.complete;
        final live = _liveRefs(e.kind, e.key).length;
        final stale = meta == null || _olderThan(meta.lastUsed, safetyWindow);
        if (!(incomplete || (live == 0 && stale))) return 0;
        final size = _treeSize(e.dir);
        if (!dryRun && e.dir.existsSync()) e.dir.deleteSync(recursive: true);
        removed.add('${e.kind}/${e.key}');
        return size;
      });
    }
    return GcReport(removed: removed, bytesFreed: freed);
  }

  bool _isComplete(String kind, String key) {
    final meta = CacheMeta.read(_metaFile(kind, key));
    return meta != null && meta.complete && rootOf(kind, key).existsSync();
  }

  Directory _touch(String kind, String key) {
    final metaF = _metaFile(kind, key);
    final meta = CacheMeta.read(metaF);
    if (meta != null) meta.touch(nowIso()).write(metaF);
    return rootOf(kind, key);
  }

  /// Backlinks whose symlink still resolves to this entry's root; dead ones are
  /// pruned as a side effect.
  List<String> _liveRefs(String kind, String key) {
    final refsDir = _refsDir(kind, key);
    if (!refsDir.existsSync()) return const [];
    final wantRoot = rootOf(kind, key).absolute.path;
    final live = <String>[];
    for (final f in refsDir.listSync().whereType<File>()) {
      final linkPath = f.readAsStringSync().trim();
      final ok =
          FileSystemEntity.typeSync(linkPath, followLinks: false) ==
              FileSystemEntityType.link &&
          _linkResolvesTo(linkPath, wantRoot);
      if (ok) {
        live.add(linkPath);
      } else {
        f.deleteSync();
      }
    }
    return live;
  }

  bool _linkResolvesTo(String linkPath, String wantRoot) {
    try {
      final tgt = Link(linkPath).targetSync();
      final resolved = p.isAbsolute(tgt)
          ? tgt
          : p.normalize(p.join(p.dirname(linkPath), tgt));
      return p.equals(resolved, wantRoot);
    } on Object {
      return false;
    }
  }

  int _treeSize(Directory d) {
    if (!d.existsSync()) return 0;
    var n = 0;
    for (final e in d.listSync(recursive: true, followLinks: false)) {
      if (e is File) {
        try {
          n += e.lengthSync();
        } on Object {
          // Unreadable entry — skip.
        }
      }
    }
    return n;
  }

  bool _olderThan(String iso, Duration window) {
    final t = DateTime.tryParse(iso);
    if (t == null) return true;
    return DateTime.now().toUtc().difference(t.toUtc()) > window;
  }
}
