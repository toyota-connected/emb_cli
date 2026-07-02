import 'dart:io';

import 'package:emb_cli/src/cache/cache_meta.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('emb_meta_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('round-trips through JSON', () {
    final f = File(p.join(tmp.path, 'meta.json'));
    const CacheMeta(
      kind: 'toolchain',
      key: 'k',
      created: '2026-01-01T00:00:00.000Z',
      lastUsed: '2026-01-02T00:00:00.000Z',
      sizeBytes: 42,
      complete: true,
      sourceUrl: 'https://x/y.tar.xz',
      sourceSha: 'abc',
    ).write(f);

    final read = CacheMeta.read(f)!;
    expect(read.kind, 'toolchain');
    expect(read.sizeBytes, 42);
    expect(read.complete, isTrue);
    expect(read.sourceUrl, 'https://x/y.tar.xz');
    expect(read.sourceSha, 'abc');
  });

  test('read returns null for a missing or garbage file', () {
    expect(CacheMeta.read(File(p.join(tmp.path, 'nope.json'))), isNull);
    final bad = File(p.join(tmp.path, 'bad.json'))
      ..writeAsStringSync('{not json');
    expect(CacheMeta.read(bad), isNull);
  });

  test('touch updates lastUsed only', () {
    const m = CacheMeta(
      kind: 'engine',
      key: 'k',
      created: 'c',
      lastUsed: 'old',
      sizeBytes: 1,
      complete: true,
    );
    final t = m.touch('new');
    expect(t.lastUsed, 'new');
    expect(t.created, 'c');
    expect(t.complete, isTrue);
  });
}
