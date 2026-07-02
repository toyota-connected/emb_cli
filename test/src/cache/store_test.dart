import 'dart:io';

import 'package:emb_cli/src/cache/cache_meta.dart';
import 'package:emb_cli/src/cache/store.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  late Store store;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('emb_store_');
    store = Store(tmp);
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  File dummyBlob() =>
      File(p.join(tmp.path, 'blob.bin'))..writeAsStringSync('bytes');

  /// A stage that writes a marker file and counts invocations.
  ({int Function() count, Future<void> Function(File, Directory) stage})
  counter() {
    var n = 0;
    return (
      count: () => n,
      stage: (File blob, Directory into) async {
        n++;
        File(p.join(into.path, 'bin', 'gcc'))
          ..createSync(recursive: true)
          ..writeAsStringSync('#!/bin/sh');
      },
    );
  }

  test('stages once, then serves from the fast path', () async {
    final c = counter();
    final root = await store.ensure(
      kind: 'toolchain',
      key: 'k1',
      fetch: () async => dummyBlob(),
      stage: c.stage,
    );
    expect(File(p.join(root.path, 'bin', 'gcc')).existsSync(), isTrue);
    expect(c.count(), 1);

    final again = await store.ensure(
      kind: 'toolchain',
      key: 'k1',
      fetch: () async => dummyBlob(),
      stage: c.stage,
    );
    expect(again.path, root.path);
    expect(c.count(), 1); // fast path — no re-stage
    expect(store.list().single.meta!.complete, isTrue);
  });

  test('re-stages an incomplete (crash-leftover) entry', () async {
    // Simulate a crash mid-extract: entry dir + partial root, no meta.
    store.entryDir('toolchain', 'k').createSync(recursive: true);
    store.rootOf('toolchain', 'k').createSync(recursive: true);
    final c = counter();
    await store.ensure(
      kind: 'toolchain',
      key: 'k',
      fetch: () async => dummyBlob(),
      stage: c.stage,
    );
    expect(c.count(), 1);
    expect(
      File(
        p.join(store.rootOf('toolchain', 'k').path, 'bin', 'gcc'),
      ).existsSync(),
      isTrue,
    );
  });

  test('materialize symlinks + backlinks; list tracks live refs', () async {
    final c = counter();
    await store.ensure(
      kind: 'toolchain',
      key: 'k',
      fetch: () async => dummyBlob(),
      stage: c.stage,
    );
    final link = p.join(tmp.path, 'ws', 'toolchain');
    store.materialize(kind: 'toolchain', key: 'k', linkPath: link);
    expect(FileSystemEntity.isLinkSync(link), isTrue);
    expect(
      Link(link).targetSync(),
      store.rootOf('toolchain', 'k').absolute.path,
    );
    expect(store.list().single.liveRefs, 1);

    // Removing the symlink makes the backlink dead → liveRefs drops to 0.
    Link(link).deleteSync();
    expect(store.list().single.liveRefs, 0);
  });

  test('gc removes incomplete + unreferenced-stale, keeps live', () async {
    final c = counter();
    // Live: fresh + referenced.
    await store.ensure(
      kind: 'toolchain',
      key: 'live',
      fetch: () async => dummyBlob(),
      stage: c.stage,
    );
    store.materialize(
      kind: 'toolchain',
      key: 'live',
      linkPath: p.join(tmp.path, 'ws', 'tc'),
    );
    // Stale + unreferenced: backdate lastUsed well past the window.
    await store.ensure(
      kind: 'engine',
      key: 'old',
      fetch: () async => dummyBlob(),
      stage: c.stage,
    );
    final metaF = File(
      p.join(store.entryDir('engine', 'old').path, 'meta.json'),
    );
    final m = CacheMeta.read(metaF)!;
    CacheMeta(
      kind: m.kind,
      key: m.key,
      created: m.created,
      lastUsed: '2000-01-01T00:00:00.000Z',
      sizeBytes: m.sizeBytes,
      complete: true,
    ).write(metaF);
    // Incomplete crash leftover.
    store.entryDir('toolchain', 'partial').createSync(recursive: true);
    store.rootOf('toolchain', 'partial').createSync(recursive: true);

    final report = await store.gc();
    expect(report.removed, containsAll(['engine/old', 'toolchain/partial']));
    expect(report.removed, isNot(contains('toolchain/live')));
    expect(store.rootOf('toolchain', 'live').existsSync(), isTrue);
    expect(store.entryDir('engine', 'old').existsSync(), isFalse);
    expect(store.entryDir('toolchain', 'partial').existsSync(), isFalse);
  });

  test('gc --dry-run reports without deleting', () async {
    store.entryDir('toolchain', 'partial').createSync(recursive: true);
    store.rootOf('toolchain', 'partial').createSync(recursive: true);
    final report = await store.gc(dryRun: true);
    expect(report.removed, ['toolchain/partial']);
    expect(store.entryDir('toolchain', 'partial').existsSync(), isTrue);
  });
}
