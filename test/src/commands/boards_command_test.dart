import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:emb_cli/src/commands/boards_command.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:mocktail/mocktail.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

class _MockLogger extends Mock implements Logger {}

void main() {
  late Logger logger;
  late Directory tmp;
  final info = <String>[];
  final warn = <String>[];

  setUp(() {
    logger = _MockLogger();
    info.clear();
    warn.clear();
    when(() => logger.info(any())).thenAnswer((i) {
      info.add('${i.positionalArguments.first}');
    });
    when(() => logger.warn(any())).thenAnswer((i) {
      warn.add('${i.positionalArguments.first}');
    });
    tmp = Directory.systemTemp.createTempSync('emb_boards_cmd_');
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  /// A data home holding one board, as an install writes it.
  void installBoards({String? stamp}) {
    final d = Directory(p.join(tmp.path, 'data', 'emb', 'boards'))
      ..createSync(recursive: true);
    File(p.join(d.path, 'raspberry-pi.emb.yaml')).writeAsStringSync('''
id: raspberry-pi
type: board
cross:
  provider: arm-gnu
  triple: aarch64-none-linux-gnu
  targets:
    rpi5-trixie: {}
''');
    if (stamp != null) {
      File(p.join(d.path, '.emb-boards-version')).writeAsStringSync(stamp);
    }
  }

  Future<int> runList(Map<String, String> env) async {
    final runner = CommandRunner<int>('emb', 'test')
      ..addCommand(BoardsCommand(logger: logger, environment: env));
    return await runner.run(['boards', 'list']) ?? 0;
  }

  /// An environment that isolates the resolver from the developer's real
  /// data dir *and* from the checkout, so rungs 3-5 are what we say they are.
  Map<String, String> envFor(String dataHome) => {
    'HOME': tmp.path,
    'XDG_DATA_HOME': dataHome,
  };

  group('emb boards list', () {
    test(
      'lists boards from the installed data dir and names the rung',
      () async {
        installBoards();
        final code = await runList(envFor(p.join(tmp.path, 'data')));
        expect(code, ExitCode.success.code);
        expect(info.join('\n'), contains('rpi5-trixie'));
        expect(
          info.first,
          contains('installed'),
          reason:
              'the source rung is the question people have when it misbehaves',
        );
      },
    );

    test('reports the stamp and flags a version mismatch', () async {
      installBoards(stamp: '0.0.1-old');
      await runList(envFor(p.join(tmp.path, 'data')));
      final out = info.join('\n');
      expect(out, contains('0.0.1-old'));
      expect(
        out,
        contains('emb is'),
        reason: 'a board library from another emb must be visible, not silent',
      );
    });

    test('an EMB_BOARDS_DIR override outranks the data dir', () async {
      installBoards();
      final other = Directory(p.join(tmp.path, 'other'))..createSync();
      File(p.join(other.path, 'b.emb.yaml')).writeAsStringSync('''
id: other
type: board
cross:
  provider: arm-gnu
  targets:
    only-here: {}
''');
      await runList({
        ...envFor(p.join(tmp.path, 'data')),
        'EMB_BOARDS_DIR': other.path,
      });
      final out = info.join('\n');
      expect(out, contains('only-here'));
      expect(out, isNot(contains('rpi5-trixie')));
    });
  });
}
