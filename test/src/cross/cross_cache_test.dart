import 'dart:io';

import 'package:emb_cli/src/cache/oci_transport.dart';
import 'package:emb_cli/src/cache/store.dart';
import 'package:emb_cli/src/cross/cross_cache.dart';
import 'package:emb_cli/src/cross/cross_keys.dart';
import 'package:emb_cli/src/cross/cross_target.dart';
import 'package:emb_cli/src/cross/process_runner.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// In-memory [OciTransport]: records pushes and serves a canned layer on pull.
class _FakeTransport implements OciTransport {
  _FakeTransport({this.existsResult = false, this.layer});

  final bool existsResult;
  final File? layer;
  final List<String> pushedRefs = [];

  @override
  String get tool => 'fake';

  @override
  Future<bool> exists(String ref) async => existsResult;

  @override
  Future<void> push(
    String ref,
    File layer, {
    Map<String, String> annotations = const {},
  }) async {
    pushedRefs.add(ref);
  }

  @override
  Future<File> pull(String ref, Directory into) async {
    final l = layer;
    // No canned layer == a registry miss; the real transport raises this.
    if (l == null) throw OciTransportException('not found: $ref');
    return File(p.join(into.path, 'layer.tar.gz'))
      ..writeAsBytesSync(l.readAsBytesSync());
  }
}

CrossTarget _target() => CrossTarget.fromMap(const {
  'provider': 'arm-gnu',
  'toolchain_version': '12.3.rel1',
  'image_url': 'https://example/raspios.img.xz',
  'cpu_flags': ['-mcpu=cortex-a76'],
});

/// The sysroot-base selector for [t].
CacheSelector _sel(CrossTarget t) =>
    (kind: 'sysroot-base', key: sysrootBaseKey(t));

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('emb_xcache_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  CrossCache cache(Store store, OciTransport transport) => CrossCache(
    registry: 'reg.example/x',
    repo: 'emb-cache',
    store: store,
    transport: transport,
    run: defaultProcessRunner,
  );

  test('fromEnv is null without a registry, configured with one', () {
    expect(
      CrossCache.fromEnv(environment: const {}, run: defaultProcessRunner),
      isNull,
    );
    final cc = CrossCache.fromEnv(
      environment: const {'EMB_CACHE_REGISTRY': 'reg.example/x'},
      run: defaultProcessRunner,
    );
    expect(cc, isNotNull);
    expect(cc!.registry, 'reg.example/x');
    expect(cc.repo, 'emb-cache');
    final override = CrossCache.fromEnv(
      environment: const {
        'EMB_CACHE_REGISTRY': 'reg.example/x',
        'EMB_CACHE_REPO': 'my-repo',
      },
      run: defaultProcessRunner,
    );
    expect(override!.repo, 'my-repo');
  });

  test('refFor keys the sysroot base by its augment-independent key', () {
    final t = _target();
    final cc = cache(Store(tmp), _FakeTransport());
    expect(
      cc.refFor(_sel(t)),
      cacheRef('reg.example/x', 'emb-cache', 'sysroot-base', sysrootBaseKey(t)),
    );
  });

  test('push skips when the ref already exists', () async {
    final fake = _FakeTransport(existsResult: true);
    // Even with a local entry present, an existing ref means no upload.
    final store = Store(tmp);
    await store.ensure(
      kind: 'sysroot-base',
      key: sysrootBaseKey(_target()),
      fetch: () async => File(p.join(tmp.path, 'noop'))..createSync(),
      stage: (_, into) async =>
          File(p.join(into.path, 'marker')).writeAsStringSync('x'),
    );
    await cache(store, fake).push([_sel(_target())]);
    expect(fake.pushedRefs, isEmpty);
  });

  test('push is a no-op when nothing is staged locally', () async {
    final fake = _FakeTransport();
    await cache(Store(tmp), fake).push([_sel(_target())]);
    expect(fake.pushedRefs, isEmpty);
  });

  test('push tars and uploads the locally-staged sysroot base', () async {
    final t = _target();
    final store = Store(tmp);
    await store.ensure(
      kind: 'sysroot-base',
      key: sysrootBaseKey(t),
      fetch: () async => File(p.join(tmp.path, 'noop'))..createSync(),
      stage: (_, into) async =>
          File(p.join(into.path, 'marker')).writeAsStringSync('x'),
    );
    final fake = _FakeTransport();
    await cache(store, fake).push([_sel(t)]);
    expect(fake.pushedRefs, [
      cacheRef('reg.example/x', 'emb-cache', 'sysroot-base', sysrootBaseKey(t)),
    ]);
  });

  test('pull populates the store from the registry layer', () async {
    final t = _target();
    // A canned layer tar.gz standing in for the pushed sysroot base.
    final src = Directory(p.join(tmp.path, 'src'))..createSync();
    File(p.join(src.path, 'os-release')).writeAsStringSync('ID=debian');
    final layer = File(p.join(tmp.path, 'layer.tar.gz'));
    final tar = await defaultProcessRunner('tar', [
      '-czf',
      layer.path,
      '-C',
      src.path,
      '.',
    ]);
    expect(tar.exitCode, 0);

    final store = Store(Directory(p.join(tmp.path, 'store'))..createSync());
    await cache(store, _FakeTransport(layer: layer)).pull([_sel(t)]);

    final root = store.rootOf('sysroot-base', sysrootBaseKey(t));
    expect(File(p.join(root.path, 'os-release')).existsSync(), isTrue);
  });

  test('pull leaves the store empty on a registry miss', () async {
    final t = _target();
    // layer == null → the fake throws in pull(); CrossCache must swallow it.
    final store = Store(Directory(p.join(tmp.path, 'store'))..createSync());
    await cache(store, _FakeTransport()).pull([_sel(t)]);
    expect(
      store.rootOf('sysroot-base', sysrootBaseKey(t)).existsSync(),
      isFalse,
    );
  });
}
