import 'dart:io';

import 'package:emb_cli/src/cache/oci_transport.dart';
import 'package:emb_cli/src/cross/process_runner.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('cacheTag / cacheRef', () {
    test('composes <kind>-<key> and a full ref', () {
      expect(cacheTag('toolchain', 'arm-gnu-12.3'), 'toolchain-arm-gnu-12.3');
      expect(
        cacheRef('ghcr.io/org', 'emb-cache', 'engine', 'abc-arm64-release'),
        'ghcr.io/org/emb-cache:engine-abc-arm64-release',
      );
    });

    test('sanitizes characters outside the tag charset', () {
      expect(cacheTag('sysroot-base', 'a/b:c'), 'sysroot-base-a-b-c');
    });

    test('truncates + hashes an over-long tag to <=128 chars, stably', () {
      final tag = cacheTag('toolchain', 'x' * 200);
      expect(tag.length, lessThanOrEqualTo(128));
      expect(cacheTag('toolchain', 'x' * 200), tag); // deterministic
    });
  });

  group('OrasTransport', () {
    late List<List<String>> calls;
    setUp(() => calls = []);

    // A fake ProcessRunner recording argv and returning [code]/[stderr].
    ProcessRunner faker(int code, {String stderr = ''}) =>
        (
          exe,
          args, {
          workingDirectory,
          environment,
          includeParentEnvironment = true,
          runInShell = false,
          output = ProcessOutputMode.capture,
          label,
        }) async {
          calls.add([exe, ...args]);
          return RunResult(code, '', stderr);
        };

    test('exists runs `oras manifest fetch` and maps the exit code', () async {
      expect(await OrasTransport(run: faker(0)).exists('reg/repo:t'), isTrue);
      expect(calls.single, ['oras', 'manifest', 'fetch', 'reg/repo:t']);
      expect(await OrasTransport(run: faker(1)).exists('reg/repo:t'), isFalse);
    });

    test('push sends the layer+mediaType and annotations', () async {
      final layer = File(p.join(Directory.systemTemp.path, 'x.tar.gz'));
      await OrasTransport(
        run: faker(0),
      ).push('reg/repo:t', layer, annotations: {'k': 'v'});
      final argv = calls.single;
      expect(argv.take(3), ['oras', 'push', 'reg/repo:t']);
      expect(argv, contains('${layer.path}:$cacheLayerMediaType'));
      expect(argv, containsAllInOrder(['--annotation', 'k=v']));
    });

    // The layer is a temp file this process just wrote, so its path is
    // absolute and oras refuses that by default -- it becomes the artifact's
    // title annotation, and a consumer could be handed something that writes
    // outside its own directory. Here the puller only ever reads the blob back,
    // so the path is incidental. Without the flag every push fails, which is
    // why the cache this transport fills had always been empty.
    test(
      'push allows the absolute layer path oras would otherwise reject',
      () async {
        final layer = File(p.join(Directory.systemTemp.path, 'x.tar.gz'));
        expect(p.isAbsolute(layer.path), isTrue, reason: 'the case under test');
        await OrasTransport(run: faker(0)).push('reg/repo:t', layer);
        expect(calls.single, contains('--disable-path-validation'));
      },
    );

    test('push throws OciTransportException on a non-zero exit', () {
      expect(
        () => OrasTransport(run: faker(1, stderr: 'boom')).push('r', File('x')),
        throwsA(isA<OciTransportException>()),
      );
    });

    test('pull runs `oras pull -o` and returns the restored tarball', () async {
      final into = Directory.systemTemp.createTempSync('emb_pull_t_');
      addTearDown(() => into.deleteSync(recursive: true));
      final t = OrasTransport(
        run:
            (
              exe,
              args, {
              workingDirectory,
              environment,
              includeParentEnvironment = true,
              runInShell = false,
              output = ProcessOutputMode.capture,
              label,
            }) async {
              calls.add([exe, ...args]);
              File(p.join(into.path, 'layer.tar.gz')).writeAsStringSync('x');
              return const RunResult(0, '', '');
            },
      );
      final f = await t.pull('reg/repo:t', into);
      expect(calls.single, ['oras', 'pull', 'reg/repo:t', '-o', into.path]);
      expect(f.path, endsWith('.tar.gz'));
    });

    test('pull throws when no layer file is produced', () {
      final into = Directory.systemTemp.createTempSync('emb_pull_e_');
      addTearDown(() => into.deleteSync(recursive: true));
      expect(
        () => OrasTransport(run: faker(0)).pull('reg/repo:t', into),
        throwsA(isA<OciTransportException>()),
      );
    });
  });
}
