import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:emb_cli/src/cache/oci_transport.dart';
import 'package:emb_cli/src/cache/store.dart';
import 'package:emb_cli/src/commands/cache_command.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Captures `info` lines for assertions.
class _CaptureLogger extends Logger {
  final StringBuffer buffer = StringBuffer();
  @override
  void info(String? message, {LogStyle? style}) => buffer.writeln(message);
}

/// An in-memory [OciTransport]: records pushes and serves a canned layer for
/// pulls. No network / no real oras.
class _FakeTransport implements OciTransport {
  _FakeTransport({this.existsResult = false, this.layer});

  final bool existsResult;

  /// A prebuilt `.tar.gz` served by [pull].
  final File? layer;

  final List<String> pushedRefs = [];
  final List<Map<String, String>> pushedAnnotations = [];

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
    pushedAnnotations.add(annotations);
  }

  @override
  Future<File> pull(String ref, Directory into) async {
    final dest = File(p.join(into.path, 'layer.tar.gz'))
      ..writeAsBytesSync(layer!.readAsBytesSync());
    return dest;
  }
}

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('emb_cachecmd_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  Future<(int?, String)> run(List<String> args) async {
    final logger = _CaptureLogger();
    final runner = CommandRunner<int>('emb', 'test')
      ..addCommand(
        CacheCommand(logger: logger, environment: {'EMB_CACHE_DIR': tmp.path}),
      );
    final code = await runner.run(args);
    return (code, logger.buffer.toString());
  }

  test('cache path prints the resolved dir', () async {
    final (code, out) = await run(['cache', 'path']);
    expect(code, ExitCode.success.code);
    expect(out.trim(), tmp.path);
  });

  test('cache list is empty by default', () async {
    final (code, out) = await run(['cache', 'list']);
    expect(code, ExitCode.success.code);
    expect(out, contains('Cache is empty'));
  });

  test('cache list --json emits the envelope with entries', () async {
    // Seed one complete store entry.
    final store = Store(tmp);
    await store.ensure(
      kind: 'toolchain',
      key: 'arm-gnu-12.3.rel1-x86_64-aarch64-none-linux-gnu',
      fetch: () async => File(p.join(tmp.path, 'b'))..writeAsStringSync('x'),
      stage: (blob, into) async =>
          File(p.join(into.path, 'f')).writeAsStringSync('1'),
    );

    final (code, out) = await run(['cache', 'list', '--json']);
    expect(code, ExitCode.success.code);
    final json = jsonDecode(out.trim()) as Map<String, dynamic>;
    expect(json['command'], 'cache list');
    final entries = (json['data'] as Map)['entries'] as List;
    expect(entries, hasLength(1));
    expect((entries.single as Map)['kind'], 'toolchain');
    expect((entries.single as Map)['complete'], true);
  });

  test('cache gc reports nothing to reclaim on a clean store', () async {
    final (code, out) = await run(['cache', 'gc']);
    expect(code, ExitCode.success.code);
    expect(out, contains('Nothing to reclaim'));
  });

  test(
    'cache gc --dry-run lists incomplete entries without deleting',
    () async {
      final store = Store(tmp);
      store.entryDir('toolchain', 'partial').createSync(recursive: true);
      store.rootOf('toolchain', 'partial').createSync(recursive: true);

      final (code, out) = await run(['cache', 'gc', '--dry-run']);
      expect(code, ExitCode.success.code);
      expect(out, contains('would remove toolchain/partial'));
      expect(store.entryDir('toolchain', 'partial').existsSync(), isTrue);
    },
  );

  test(
    'cache migrate adopts toolchain/engine trees and symlinks them',
    () async {
      // A workspace with un-migrated (real) toolchain + engine trees.
      final ws = Directory(p.join(tmp.path, 'ws'))..createSync();
      final fw = p.join(ws.path, '.config', 'flutter_workspace');
      const tcName =
          'arm-gnu-toolchain-12.3.rel1-x86_64-aarch64-none-linux-gnu';
      final tc = Directory(p.join(fw, 'cross-aarch64-x-y', 'toolchain', tcName))
        ..createSync(recursive: true);
      File(p.join(tc.path, 'bin', 'gcc')).createSync(recursive: true);
      final eng = Directory(
        p.join(fw, 'flutter-engine', 'abc123', 'engine-sdk-release-arm64'),
      )..createSync(recursive: true);
      File(
        p.join(eng.path, 'lib', 'libflutter_engine.so'),
      ).createSync(recursive: true);

      Future<(int?, String)> migrate(List<String> extra) async {
        final logger = _CaptureLogger();
        final runner = CommandRunner<int>('emb', 'test')
          ..addCommand(
            CacheCommand(
              logger: logger,
              environment: {'EMB_CACHE_DIR': tmp.path},
            ),
          );
        final code = await runner.run([
          'cache',
          'migrate',
          '-w',
          ws.path,
          ...extra,
        ]);
        return (code, logger.buffer.toString());
      }

      // --dry-run reports but moves nothing.
      final (dc, dout) = await migrate(['--dry-run']);
      expect(dc, ExitCode.success.code);
      expect(dout, contains('would adopt toolchain/$tcName'));
      expect(dout, contains('would adopt engine/abc123-arm64-release'));
      expect(tc.existsSync(), isTrue);

      // Real migrate: trees move into the store, dirs become symlinks.
      final (mc, _) = await migrate(const []);
      expect(mc, ExitCode.success.code);
      final store = Store(tmp);
      expect(
        store.list().map((e) => '${e.kind}/${e.key}'),
        containsAll(['toolchain/$tcName', 'engine/abc123-arm64-release']),
      );
      expect(FileSystemEntity.isLinkSync(tc.path), isTrue);
      expect(FileSystemEntity.isLinkSync(eng.path), isTrue);
      expect(
        File(p.join(tc.path, 'bin', 'gcc')).existsSync(),
        isTrue,
        reason: 'resolves through the symlink into the store',
      );
    },
  );

  group('push / pull', () {
    const key = 'arm-gnu-12.3.rel1-x86_64-aarch64-none-linux-gnu';

    // Seed one complete toolchain entry with a marker file in its root.
    Future<Store> seed() async {
      final store = Store(tmp);
      await store.ensure(
        kind: 'toolchain',
        key: key,
        fetch: () async => File(p.join(tmp.path, 'b'))..writeAsStringSync('x'),
        stage: (blob, into) async => File(p.join(into.path, 'bin', 'gcc'))
          ..createSync(recursive: true)
          ..writeAsStringSync('#!/bin/sh'),
      );
      return store;
    }

    Future<(int?, String)> pushCmd(
      List<String> args,
      _FakeTransport transport,
    ) async {
      final logger = _CaptureLogger();
      final runner = CommandRunner<int>('emb', 'test')
        ..addCommand(
          CachePushCommand(
            logger: logger,
            environment: {'EMB_CACHE_DIR': tmp.path},
            transport: transport,
          ),
        );
      final code = await runner.run(['push', ...args]);
      return (code, logger.buffer.toString());
    }

    Future<(int?, String)> pullCmd(
      List<String> args,
      _FakeTransport transport,
    ) async {
      final logger = _CaptureLogger();
      final runner = CommandRunner<int>('emb', 'test')
        ..addCommand(
          CachePullCommand(
            logger: logger,
            environment: {'EMB_CACHE_DIR': tmp.path},
            transport: transport,
          ),
        );
      final code = await runner.run(['pull', ...args]);
      return (code, logger.buffer.toString());
    }

    test('push with no registry is a usage error', () async {
      await seed();
      final (code, _) = await pushCmd([], _FakeTransport());
      expect(code, ExitCode.usage.code);
    });

    test('push --dry-run lists the ref without uploading', () async {
      await seed();
      final t = _FakeTransport();
      final (code, out) = await pushCmd([
        '--registry',
        'reg.io/org',
        '--dry-run',
      ], t);
      expect(code, ExitCode.success.code);
      expect(out, contains('reg.io/org/emb-cache:toolchain-$key'));
      expect(t.pushedRefs, isEmpty);
    });

    test('push uploads a tar layer with annotations', () async {
      await seed();
      final t = _FakeTransport();
      final (code, _) = await pushCmd(['--registry', 'reg.io/org'], t);
      expect(code, ExitCode.success.code);
      expect(t.pushedRefs, ['reg.io/org/emb-cache:toolchain-$key']);
      expect(t.pushedAnnotations.single['dev.emb.cache.kind'], 'toolchain');
      expect(t.pushedAnnotations.single['dev.emb.cache.key'], key);
    });

    test('push skips an entry that already exists (no --force)', () async {
      await seed();
      final t = _FakeTransport(existsResult: true);
      final (code, out) = await pushCmd(['--registry', 'reg.io/org'], t);
      expect(code, ExitCode.success.code);
      expect(t.pushedRefs, isEmpty);
      expect(out, contains('skip (exists)'));
    });

    test('pull stages an entry into the store from the registry', () async {
      // Build a real .tar.gz of a tree the fake transport will serve.
      final srcTree = Directory(p.join(tmp.path, 'src'))..createSync();
      File(p.join(srcTree.path, 'bin', 'gcc'))
        ..createSync(recursive: true)
        ..writeAsStringSync('#!/bin/sh');
      final layer = File(p.join(tmp.path, 'layer.tar.gz'));
      final tar = await Process.run('tar', [
        '-czf',
        layer.path,
        '-C',
        srcTree.path,
        '.',
      ]);
      expect(tar.exitCode, 0);

      final t = _FakeTransport(layer: layer);
      final (code, out) = await pullCmd([
        '--registry',
        'reg.io/org',
        'toolchain/$key',
      ], t);
      expect(code, ExitCode.success.code);
      expect(out, contains('pulled reg.io/org/emb-cache:toolchain-$key'));

      final store = Store(tmp);
      expect(
        store.list().map((e) => '${e.kind}/${e.key}'),
        contains('toolchain/$key'),
      );
      expect(
        File(
          p.join(store.rootOf('toolchain', key).path, 'bin', 'gcc'),
        ).existsSync(),
        isTrue,
      );
    });

    test('pull with no selectors is a usage error', () async {
      final (code, _) = await pullCmd([
        '--registry',
        'reg.io/org',
      ], _FakeTransport());
      expect(code, ExitCode.usage.code);
    });
  });
}
