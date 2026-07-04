import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:emb_cli/src/commands/fetch_command.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:mocktail/mocktail.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

class _MockLogger extends Mock implements Logger {}

void main() {
  late Logger logger;
  late CommandRunner<int> runner;
  late Directory tmp;

  setUp(() {
    logger = _MockLogger();
    runner = CommandRunner<int>('emb', 'test')
      ..addCommand(FetchCommand(logger: logger));
    tmp = Directory.systemTemp.createTempSync('emb_fetch_');
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  test('no arguments prints usage and exits usage', () async {
    final code = await runner.run(['fetch']);
    expect(code, ExitCode.usage.code);
    verify(() => logger.err(any(that: contains('Usage: emb fetch')))).called(1);
  });

  test('a missing manifest exits usage', () async {
    final code = await runner.run(['fetch', p.join(tmp.path, 'nope.emb.yaml')]);
    expect(code, ExitCode.usage.code);
    verify(() => logger.err(any(that: contains('No emb manifest')))).called(1);
  });

  test('an unknown target on a real manifest exits usage', () async {
    final manifest = File(p.join(tmp.path, 'app.emb.yaml'))
      ..writeAsStringSync('''
cross:
  provider: arm-gnu
  image_url: https://example/os.img.xz
''');
    final code = await runner.run(['fetch', manifest.path, '-t', 'nope']);
    expect(code, ExitCode.usage.code);
    verify(
      () => logger.err(any(that: contains('Unknown target "nope"'))),
    ).called(1);
  });

  test('a native target needs no fetch and succeeds', () async {
    final manifest = File(p.join(tmp.path, 'app.emb.yaml'))
      ..writeAsStringSync('''
cross:
  provider: arm-gnu
  image_url: https://example/os.img.xz
''');
    final code = await runner.run(['fetch', manifest.path, '-t', 'local']);
    expect(code, ExitCode.success.code);
    verify(
      () => logger.info(any(that: contains('nothing to fetch'))),
    ).called(1);
  });
}
