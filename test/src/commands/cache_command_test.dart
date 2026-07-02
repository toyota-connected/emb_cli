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
}
