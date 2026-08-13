import 'dart:io';

import 'package:emb_cli/src/cache/store.dart';
import 'package:emb_cli/src/engine/engine_builder.dart';
import 'package:emb_cli/src/engine/engine_offline_probe.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  late Store store;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('emb-engine-probe-test-');
    store = Store(Directory(p.join(tmp.path, 'cache')));
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  Future<void> seedClosure(String commit) async {
    final src = Directory(p.join(tmp.path, 'src-$commit'))
      ..createSync(recursive: true);
    await store.adopt(
      kind: EngineBuilder.srcKind,
      key: commit,
      existingDir: src,
    );
  }

  test('not ok when the closure is missing', () async {
    final r = await EngineOfflineProbe(store: store).probe(commit: 'abc');
    expect(r.closureReady, isFalse);
    expect(r.ok, isFalse);
  });

  test('ok (non-strict) when the closure is present', () async {
    await seedClosure('abc');
    final r = await EngineOfflineProbe(store: store).probe(commit: 'abc');
    expect(r.closureReady, isTrue);
    expect(r.isolationOk, isNull);
    expect(r.ok, isTrue);
  });

  test('strict also requires network isolation', () async {
    await seedClosure('abc');
    final noIso = await EngineOfflineProbe(
      store: store,
      isolationAvailable: () async => false,
    ).probe(commit: 'abc', strict: true);
    expect(noIso.isolationOk, isFalse);
    expect(noIso.ok, isFalse);

    final yesIso = await EngineOfflineProbe(
      store: store,
      isolationAvailable: () async => true,
    ).probe(commit: 'abc', strict: true);
    expect(yesIso.ok, isTrue);
  });
}
