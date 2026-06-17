import 'dart:io';

import 'package:emb_cli/src/cross/runnable_bundle.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('emb_run_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  /// A minimal assembled bundle (data/ + lib/), as the pipeline would produce.
  Directory bundle() {
    final b = Directory(p.join(tmp.path, 'runnable'));
    File(p.join(b.path, 'data', 'flutter_assets', 'x'))
      ..createSync(recursive: true)
      ..writeAsStringSync('a');
    File(p.join(b.path, 'data', 'icudtl.dat')).createSync(recursive: true);
    File(
      p.join(b.path, 'lib', 'libflutter_engine.so'),
    ).createSync(recursive: true);
    return b;
  }

  File embedder() =>
      File(p.join(tmp.path, 'homescreen'))
        ..writeAsBytesSync([0x7f, 0x45, 0x4c, 0x46]);

  test(
    'install drops the embedder beside data/ and makes it executable',
    () async {
      final b = bundle();
      final bin = await RunnableBundle().install(embedder(), b);

      expect(bin.path, p.join(b.path, 'homescreen'));
      expect(bin.existsSync(), isTrue);
      // 0755 — owner-executable at least.
      expect(bin.statSync().mode & 0x40, isNot(0));
    },
  );

  test('install rejects a dir with no Flutter bundle', () async {
    final empty = Directory(p.join(tmp.path, 'empty'))..createSync();
    expect(
      () => RunnableBundle().install(embedder(), empty),
      throwsA(isA<RunnableBundleException>()),
    );
  });

  test('install rejects a missing embedder', () async {
    expect(
      () => RunnableBundle().install(File(p.join(tmp.path, 'nope')), bundle()),
      throwsA(isA<RunnableBundleException>()),
    );
  });

  test('tar produces a .tar.gz of the tree', () async {
    final b = bundle();
    await RunnableBundle().install(embedder(), b);
    final archive = await RunnableBundle().tar(b);

    expect(archive.path, '${b.path}.tar.gz');
    expect(archive.existsSync(), isTrue);
    expect(archive.lengthSync(), greaterThan(0));
  });
}
