import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
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
}
