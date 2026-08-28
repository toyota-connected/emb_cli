import 'dart:io';

import 'package:emb_cli/src/cache/cas.dart';
import 'package:emb_cli/src/cache/store.dart';
import 'package:emb_cli/src/engine/engine_artifacts.dart';
import 'package:emb_cli/src/host/host_info.dart';
import 'package:emb_cli/src/workspace/workspace.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// A [Cas] that returns a fixed blob and counts how often it is asked — so a
/// test can assert the engine SDK is downloaded once and shared.
class _FakeCas extends Cas {
  _FakeCas(super.root, this.blob);
  final File blob;
  int calls = 0;
  @override
  Future<File> ensure(String url, {String? expectedSha}) async {
    calls++;
    return blob;
  }
}

void main() {
  group('engineArch', () {
    test('maps x64/x86_64/amd64 to x86_64', () {
      expect(EngineArtifacts.engineArch('x64'), 'x86_64');
      expect(EngineArtifacts.engineArch('x86_64'), 'x86_64');
      expect(EngineArtifacts.engineArch('AMD64'), 'x86_64');
    });
    test('maps arm/armv7hf to armv7hf', () {
      expect(EngineArtifacts.engineArch('arm'), 'armv7hf');
      expect(EngineArtifacts.engineArch('armv7hf'), 'armv7hf');
    });
    test('maps arm64/aarch64 to arm64', () {
      expect(EngineArtifacts.engineArch('arm64'), 'arm64');
      expect(EngineArtifacts.engineArch('aarch64'), 'arm64');
    });
    test('passes through riscv64', () {
      expect(EngineArtifacts.engineArch('riscv64'), 'riscv64');
    });
  });

  group('engineArchForHost', () {
    test('resolves the engine token from the host machine arch', () {
      const host = HostInfo(
        os: HostOs.linux,
        machineArch: 'aarch64',
        archAliases: {'aarch64', 'arm64'},
        hostType: 'fedora',
        versionId: '43',
      );
      expect(EngineArtifacts.engineArchForHost(host), 'arm64');
    });
  });

  group('engineSdkUrl', () {
    test('builds the meta-flutter release URL', () {
      final url = EngineArtifacts.engineSdkUrl('release', 'x64', 'abc123');
      expect(
        url,
        'https://github.com/meta-flutter/flutter-engine/releases/download/'
        'linux-engine-sdk-release-x86_64-abc123/'
        'linux-engine-sdk-release-x86_64-abc123.tar.gz',
      );
    });

    test('uses the mapped arch token', () {
      final url = EngineArtifacts.engineSdkUrl('debug', 'arm', 'deadbeef');
      expect(url, contains('linux-engine-sdk-debug-armv7hf-deadbeef'));
    });
  });

  group('engineKey', () {
    test('is the store key, with the arch token normalized', () {
      expect(
        EngineArtifacts.engineKey('release', 'x64', 'abc123'),
        'abc123-x86_64-release',
      );
      expect(
        EngineArtifacts.engineKey('release', 'x86_64', 'abc123'),
        'abc123-x86_64-release',
      );
      expect(
        EngineArtifacts.engineKey('debug', 'aarch64', 'def456'),
        'def456-arm64-debug',
      );
    });
  });

  group('fetch (store)', () {
    late Directory tmp;
    late Directory cache;
    setUp(() {
      tmp = Directory.systemTemp.createTempSync('emb_eng_');
      cache = Directory.systemTemp.createTempSync('emb_eng_cache_');
    });
    tearDown(() {
      tmp.deleteSync(recursive: true);
      cache.deleteSync(recursive: true);
    });

    /// Builds a one-file engine SDK tarball whose libflutter_engine.so carries
    /// [marker], so a staged bundle can be traced back to the artifact it came
    /// from.
    Future<File> seedSdk(String name, String marker) async {
      final src = Directory(p.join(tmp.path, name))..createSync();
      for (final e in {
        'data/icudtl.dat': 'icu-$marker',
        'lib/libflutter_engine.so': 'engine-$marker',
      }.entries) {
        File(p.join(src.path, 'engine-sdk', e.key))
          ..createSync(recursive: true)
          ..writeAsStringSync(e.value);
      }
      final out = File(p.join(tmp.path, '$name.tar.gz'));
      final rc = await Process.run('tar', [
        '-czf',
        out.path,
        '-C',
        src.path,
        'engine-sdk',
      ]);
      expect(rc.exitCode, 0, reason: '${rc.stderr}');
      return out;
    }

    // The staged bundle lives at bundle-<runtime>-<arch>, with no commit in the
    // path, while the engine SDK beside it is keyed by commit. Without a stamp
    // the first commit ever fetched wins forever: gen_snapshot moves to the new
    // commit and the bundle keeps serving the old libflutter_engine.so, so the
    // AOT snapshot and the engine disagree at launch rather than at build time.
    test('an engine commit bump restages the bundle', () async {
      final store = Store(cache);
      final ws = Directory(p.join(tmp.path, 'ws'))..createSync();

      Future<EngineFetchResult> fetchCommit(String commit, File blob) =>
          EngineArtifacts(
            Workspace(ws),
            cas: _FakeCas(cache, blob),
            store: store,
          ).fetch(runtime: 'release', arch: 'x86_64', commit: commit);

      final first = await fetchCommit('aaa111', await seedSdk('sdk1', 'old'));
      expect(first.ok, isTrue, reason: first.message);
      final staged = File(
        p.join(first.bundleDir!, 'lib', 'libflutter_engine.so'),
      );
      expect(staged.readAsStringSync(), 'engine-old');

      final second = await fetchCommit('bbb222', await seedSdk('sdk2', 'new'));
      expect(second.ok, isTrue, reason: second.message);
      expect(
        second.bundleDir,
        first.bundleDir,
        reason: 'the bundle path is not keyed by commit; that is the hazard',
      );
      expect(
        staged.readAsStringSync(),
        'engine-new',
        reason: 'a commit bump must restage, not serve the old engine',
      );
    });

    test('a second fetch of the same commit is up to date', () async {
      final store = Store(cache);
      final ws = Directory(p.join(tmp.path, 'ws'))..createSync();
      final blob = await seedSdk('sdk', 'same');
      Future<EngineFetchResult> once() => EngineArtifacts(
        Workspace(ws),
        cas: _FakeCas(cache, blob),
        store: store,
      ).fetch(runtime: 'release', arch: 'x86_64', commit: 'aaa111');

      expect((await once()).status, EngineFetchStatus.fetched);
      expect((await once()).status, EngineFetchStatus.upToDate);
    });

    // fetch() builds the bundle path itself; BundleBuilder reads it back with
    // the normalized token. Built from the raw arch the two disagree, and a
    // caller passing 'x64' stages into a directory nothing consumes.
    test('the bundle path uses the normalized arch token', () async {
      final store = Store(cache);
      final ws = Directory(p.join(tmp.path, 'ws'))..createSync();
      final blob = await seedSdk('sdk', 'x');
      final r = await EngineArtifacts(
        Workspace(ws),
        cas: _FakeCas(cache, blob),
        store: store,
      ).fetch(runtime: 'release', arch: 'x64', commit: 'aaa111');
      expect(r.ok, isTrue, reason: r.message);
      expect(p.basename(r.bundleDir!), 'bundle-release-x86_64');
    });

    test('stores the SDK once and symlinks it into each workspace', () async {
      // A tiny engine SDK tarball with the gen_snapshot clang sibling layout.
      final src = Directory(p.join(tmp.path, 'sdk'))..createSync();
      void seed(String rel, String body) =>
          File(p.join(src.path, 'engine-sdk', rel))
            ..createSync(recursive: true)
            ..writeAsStringSync(body);
      seed('data/icudtl.dat', 'icu');
      seed('lib/libflutter_engine.so', 'eng');
      seed('clang_x64/bin/gen_snapshot', '#');
      seed('clang_x64/lib64/libc++.so', '#');
      final fixture = File(p.join(tmp.path, 'engine.tar.gz'));
      final rc = await Process.run('tar', [
        '-czf',
        fixture.path,
        '-C',
        src.path,
        'engine-sdk',
      ]);
      expect(rc.exitCode, 0, reason: '${rc.stderr}');

      final store = Store(cache);
      final cas = _FakeCas(cache, fixture);

      Future<EngineFetchResult> fetchIn(Directory ws) => EngineArtifacts(
        Workspace(ws),
        cas: cas,
        store: store,
      ).fetch(runtime: 'release', arch: 'x86_64', commit: 'abc123');

      final ws1 = Directory(p.join(tmp.path, 'ws1'))..createSync();
      final ws2 = Directory(p.join(tmp.path, 'ws2'))..createSync();
      final r1 = await fetchIn(ws1);
      final r2 = await fetchIn(ws2);
      expect(r1.ok, isTrue, reason: r1.message);
      expect(r2.ok, isTrue, reason: r2.message);
      // Downloaded + extracted once, shared across workspaces.
      expect(cas.calls, 1);

      final eng = store.list().where((e) => e.kind == 'engine').toList();
      expect(eng, hasLength(1));
      expect(eng.single.liveRefs, 2);

      final root = store.rootOf('engine', 'abc123-x86_64-release');
      // gen_snapshot's clang_x64/bin↔lib64 siblings are preserved in the store.
      expect(
        File(
          p.join(root.path, 'engine-sdk', 'clang_x64', 'bin', 'gen_snapshot'),
        ).existsSync(),
        isTrue,
      );
      expect(
        File(
          p.join(root.path, 'engine-sdk', 'clang_x64', 'lib64', 'libc++.so'),
        ).existsSync(),
        isTrue,
      );

      // Each workspace symlinks its engine-sdk path into the one store entry,
      // and stages the bundle from it.
      for (final ws in [ws1, ws2]) {
        final link = p.join(
          ws.path,
          '.config',
          'flutter_workspace',
          'flutter-engine',
          'abc123',
          'engine-sdk-release-x86_64',
        );
        expect(FileSystemEntity.isLinkSync(link), isTrue);
        expect(Link(link).targetSync(), root.absolute.path);
      }
      expect(
        File(p.join(r1.bundleDir!, 'data', 'icudtl.dat')).existsSync(),
        isTrue,
      );
      expect(
        File(p.join(r1.bundleDir!, 'lib', 'libflutter_engine.so')).existsSync(),
        isTrue,
      );
    });
  });
}
