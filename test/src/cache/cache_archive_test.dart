import 'dart:io';

import 'package:emb_cli/src/cache/cache_archive.dart';
import 'package:emb_cli/src/cross/process_runner.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

bool get _haveZstd =>
    Process.runSync('sh', ['-c', 'command -v zstd']).exitCode == 0;

void main() {
  group('archiveDirs', () {
    test('cas-only keeps just the blobs', () {
      expect(archiveDirs(casOnly: true), ['cas']);
    });
    test('a full archive keeps the durable dirs', () {
      expect(archiveDirs(casOnly: false), durableCacheDirs);
      expect(
        durableCacheDirs,
        containsAll(['cas', 'store', 'cargo-vendor', 'pub-cache']),
      );
    });
  });

  group('archiveManifest', () {
    test('records schema, version, cas-only, dirs, created', () {
      final m = archiveManifest(
        embVersion: '0.1.0',
        casOnly: true,
        dirs: const ['cas'],
        created: '2024-06-01T00:00:00.000Z',
      );
      expect(m['schema'], 1);
      expect(m['emb_version'], '0.1.0');
      expect(m['cas_only'], true);
      expect(m['dirs'], ['cas']);
      expect(m['created'], '2024-06-01T00:00:00.000Z');
      expect(m.containsKey('env_image'), isFalse);
    });

    test('records the pinned build-environment image when given', () {
      final m = archiveManifest(
        embVersion: '0.1.0',
        casOnly: false,
        dirs: const ['cas'],
        created: 't',
        envImage: 'ghcr.io/acme/emb-cross@sha256:${'a' * 64}',
      );
      expect(m['env_image'], 'ghcr.io/acme/emb-cross@sha256:${'a' * 64}');
    });
  });

  group('isImageDigestPinned', () {
    test('true for a digest reference', () {
      expect(
        isImageDigestPinned('ghcr.io/acme/emb-cross@sha256:${'a' * 64}'),
        isTrue,
      );
    });
    test('false for a mutable tag', () {
      expect(isImageDigestPinned('ghcr.io/acme/emb-cross:latest'), isFalse);
      expect(isImageDigestPinned('emb-cross'), isFalse);
    });
  });

  group('exportTarArgs', () {
    test(
      'packs the dirs from root plus the manifest, zstd + deterministic',
      () {
        final a = exportTarArgs(
          archive: '/out/closure.tar.zst',
          root: '/cache',
          dirs: const ['cas', 'store'],
          manifestDir: '/tmp/m',
          epoch: 1700000000,
        );
        expect(a, containsAllInOrder(['-C', '/cache', 'cas', 'store']));
        expect(a, containsAllInOrder(['-C', '/tmp/m', archiveManifestName]));
        expect(a, containsAllInOrder(['-cf', '/out/closure.tar.zst']));
        expect(a, contains('--zstd'));
        expect(a, contains('--sort=name'));
        expect(a, contains('--mtime=@1700000000'));
        expect(a, contains('--exclude=locks'));
      },
    );

    test('omits the mtime clamp when no epoch is given', () {
      final a = exportTarArgs(
        archive: 'x',
        root: '/c',
        dirs: const ['cas'],
        manifestDir: '/m',
      );
      expect(a.where((s) => s.startsWith('--mtime')), isEmpty);
    });
  });

  group('importTarArgs', () {
    test('extracts the archive into root', () {
      expect(importTarArgs(archive: '/a.tar.zst', root: '/cache'), [
        '--zstd',
        '-xf',
        '/a.tar.zst',
        '-C',
        '/cache',
      ]);
    });
  });

  group('export/import round-trip', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('emb_escrow_'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test(
      'a blob survives export then import into a fresh cache',
      () async {
        final srcRoot = Directory(p.join(tmp.path, 'src'))..createSync();
        File(p.join(srcRoot.path, 'cas', 'sha256', 'ab', 'blob'))
          ..createSync(recursive: true)
          ..writeAsStringSync('payload');
        // A transient lock that must be excluded.
        File(p.join(srcRoot.path, 'cas', 'locks', 'x.lock'))
          ..createSync(recursive: true)
          ..writeAsStringSync('');
        final manifestDir = Directory(p.join(tmp.path, 'mf'))..createSync();
        File(
          p.join(manifestDir.path, archiveManifestName),
        ).writeAsStringSync('{}');
        final archive = p.join(tmp.path, 'closure.tar.zst');

        final export = await defaultProcessRunner(
          'tar',
          exportTarArgs(
            archive: archive,
            root: srcRoot.path,
            dirs: const ['cas'],
            manifestDir: manifestDir.path,
          ),
        );
        expect(export.exitCode, 0, reason: export.stderr);

        final dstRoot = Directory(p.join(tmp.path, 'dst'))..createSync();
        final import = await defaultProcessRunner(
          'tar',
          importTarArgs(archive: archive, root: dstRoot.path),
        );
        expect(import.exitCode, 0, reason: import.stderr);

        expect(
          File(
            p.join(dstRoot.path, 'cas', 'sha256', 'ab', 'blob'),
          ).readAsStringSync(),
          'payload',
        );
        // The excluded lock did not travel.
        expect(
          Directory(p.join(dstRoot.path, 'cas', 'locks')).existsSync(),
          isFalse,
        );
        expect(
          File(p.join(dstRoot.path, archiveManifestName)).existsSync(),
          isTrue,
        );
      },
      skip: _haveZstd ? false : 'zstd not installed',
    );
  });
}
