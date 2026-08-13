import 'dart:io';

import 'package:emb_cli/src/cache/store.dart';
import 'package:emb_cli/src/cross/apk_index.dart';
import 'package:emb_cli/src/cross/apk_sysroot.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

const _index = '''
P:musl
V:1.2.5-r0
A:aarch64
p:so:libc.musl-aarch64.so.1=1

P:musl-dev
V:1.2.5-r0
A:aarch64
D:musl=1.2.5-r0
''';

void main() {
  late Directory tmp;
  late Store store;
  late ApkIndex index;
  const spec = ApkSysrootSpec(arch: 'aarch64', devPackages: ['musl-dev']);

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('emb-apk-sysroot-test-');
    store = Store(Directory(p.join(tmp.path, 'cache')));
    index = parseApkIndex(_index, repoBase: spec.repoBase('main'));
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  test('spec builds the index and repo urls', () {
    expect(spec.indexUrls(), [
      '${spec.repoBase('main')}/APKINDEX.tar.gz',
      '${spec.repoBase('community')}/APKINDEX.tar.gz',
    ]);
  });

  test('plan resolves the closure, urls, and a deterministic key', () {
    final builder = AlpineApkSysroot(
      store: store,
      fetch: (_) async => throw StateError('unused'),
      extract: (_, _) async {},
    );
    final planA = builder.plan(spec, index);
    expect(planA.packages.map((p) => p.name).toSet(), {'musl-dev', 'musl'});
    expect(
      planA.urls,
      contains('${spec.repoBase('main')}/musl-dev-1.2.5-r0.apk'),
    );
    // Stable across runs, and prefixed by branch/arch.
    expect(planA.key, startsWith('alpine-edge-aarch64-'));
    expect(builder.plan(spec, index).key, planA.key);
  });

  test('materialize fetches+extracts once, then serves the cache', () async {
    var fetches = 0;
    final builder = AlpineApkSysroot(
      store: store,
      fetch: (url) async {
        fetches++;
        final f = File(p.join(tmp.path, 'dl', p.basename(url)))
          ..createSync(recursive: true);
        return f;
      },
      extract: (apk, dest) async {
        File(p.join(dest.path, 'usr', 'lib', 'marker'))
          ..createSync(recursive: true)
          ..writeAsStringSync(p.basename(apk.path));
      },
    );

    final root = await builder.materialize(spec, index);
    expect(root.existsSync(), isTrue);
    expect(fetches, 2, reason: 'musl-dev + its musl dep');

    final again = await builder.materialize(spec, index);
    expect(again.path, root.path);
    expect(fetches, 2, reason: 'a cache hit must not re-fetch');
  });
}
