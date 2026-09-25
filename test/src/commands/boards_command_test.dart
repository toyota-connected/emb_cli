import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:emb_cli/src/commands/boards_command.dart';
import 'package:emb_cli/src/cross/board_source.dart';
import 'package:emb_cli/src/cross/process_runner.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:mocktail/mocktail.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

class _MockLogger extends Mock implements Logger {}

class _MockProgress extends Mock implements Progress {}

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

  group('emb boards add', () {
    final err = <String>[];

    setUp(() {
      when(() => logger.err(any())).thenAnswer((i) {
        err.add('${i.positionalArguments.first}');
      });
      err.clear();
    });

    Future<int> runAdd(List<String> args) async {
      Directory(p.join(tmp.path, 'config', 'emb'))
          .createSync(recursive: true);
      final runner = CommandRunner<int>('emb', 'test')
        ..addCommand(
          BoardsCommand(
            logger: logger,
            environment: {
              'HOME': tmp.path,
              'XDG_CONFIG_HOME': p.join(tmp.path, 'config'),
            },
          ),
        );
      return await runner.run(['boards', 'add', ...args]) ?? 0;
    }

    test('rejects names with path-traversal characters', () async {
      final code = await runAdd([
        'github', 'org/repo', '--name', '../escape',
      ]);
      expect(code, ExitCode.usage.code);
      expect(err.join(), contains('Invalid source name'));
    });

    test('rejects names starting with a dash', () async {
      final code = await runAdd([
        'github', 'org/repo', '--name', '-bad',
      ]);
      expect(code, ExitCode.usage.code);
      expect(err.join(), contains('Invalid source name'));
    });

    test('accepts valid names', () async {
      when(() => logger.info(any())).thenAnswer((_) {});
      final code = await runAdd([
        'github', 'org/repo', '--name', 'my-boards_2',
      ]);
      expect(code, ExitCode.success.code);
    });
  });

  group('emb boards sync (ssh)', () {
    late Progress progress;
    late List<List<String>> calls;
    final err = <String>[];

    setUp(() {
      progress = _MockProgress();
      when(() => logger.progress(any())).thenReturn(progress);
      when(() => logger.err(any())).thenAnswer((i) {
        err.add('${i.positionalArguments.first}');
      });
      err.clear();
      calls = [];
    });

    const fakeSha = 'abc123def456';

    ProcessRunner fakeRunner({
      bool Function(String, List<String>)? failOn,
      String sha = fakeSha,
    }) {
      return (
        String exe,
        List<String> args, {
        String? workingDirectory,
        Map<String, String>? environment,
        bool includeParentEnvironment = true,
        bool runInShell = false,
        ProcessOutputMode output = ProcessOutputMode.capture,
        String? label,
      }) async {
        calls.add([exe, ...args]);
        final fail = failOn?.call(exe, args) ?? false;
        if (fail) return const RunResult(1, '', 'simulated failure');

        if (exe == 'git' && args.contains('ls-remote')) {
          final hasDeref = args.any((a) => a.contains('^{}'));
          if (hasDeref) {
            return RunResult(
              0,
              'tag-object-sha\trefs/tags/main\n'
              '$sha\trefs/tags/main^{}\n',
              '',
            );
          }
          return RunResult(0, '$sha\trefs/heads/main', '');
        }
        if (exe == 'git' && args.contains('clone')) {
          final dest = args.last;
          final boardsDir = Directory(p.join(dest, 'boards'))
            ..createSync(recursive: true);
          File(p.join(boardsDir.path, 'test-board.emb.yaml'))
              .writeAsStringSync('id: test-board\n');
        }
        return const RunResult(0, '', '');
      };
    }

    Future<int> runSync({
      required ProcessRunner runner,
      List<String> extra = const [],
    }) async {
      final configDir = Directory(p.join(tmp.path, 'config', 'emb'))
        ..createSync(recursive: true);
      BoardSourceConfig([
        const GithubBoardSource(
          name: 'priv',
          repo: 'org/priv-boards',
          transport: 'ssh',
        ),
      ]).save(File(p.join(configDir.path, 'boards.yaml')));

      final env = {
        'HOME': tmp.path,
        'XDG_CONFIG_HOME': p.join(tmp.path, 'config'),
        'XDG_DATA_HOME': p.join(tmp.path, 'data'),
      };
      final cmdRunner = CommandRunner<int>('emb', 'test')
        ..addCommand(
          BoardsCommand(
            logger: logger,
            environment: env,
            processRunner: runner,
          ),
        );
      return await cmdRunner.run([
        'boards',
        'sync',
        '--source',
        'priv',
        ...extra,
      ]) ??
          0;
    }

    test('clones via SSH and copies board files', () async {
      final code = await runSync(runner: fakeRunner());
      expect(code, ExitCode.success.code);

      expect(calls[0], contains('ls-remote'));
      expect(
        calls[0],
        contains('git@github.com:org/priv-boards.git'),
      );

      expect(calls[1], contains('clone'));
      expect(calls[1], contains('--branch'));
      expect(calls[1], contains('main'));

      expect(calls[2], contains('sparse-checkout'));
      expect(calls[2], contains('boards'));

      final installed = File(
        p.join(
          tmp.path, 'data', 'emb', 'boards', 'priv',
          'test-board.emb.yaml',
        ),
      );
      expect(installed.existsSync(), isTrue);

      verify(
        () => progress.complete(
          any(that: contains('1 board file')),
        ),
      ).called(1);
    });

    test('skips clone when SHA is unchanged', () async {
      final runner = fakeRunner();
      await runSync(runner: runner);
      calls.clear();

      final code = await runSync(runner: runner);
      expect(code, ExitCode.success.code);
      expect(calls, hasLength(1));
      expect(calls[0], contains('ls-remote'));
      verify(
        () => progress.complete(any(that: contains('up to date'))),
      ).called(1);
    });

    test('reports failure when clone fails', () async {
      final code = await runSync(
        runner: fakeRunner(
          failOn: (exe, args) => args.contains('clone'),
        ),
      );
      expect(code, ExitCode.unavailable.code);
      verify(
        () => progress.fail(any(that: contains('Could not sync'))),
      ).called(1);
    });

    test('passes --ref override to clone --branch', () async {
      await runSync(
        runner: fakeRunner(),
        extra: ['--ref', 'v1.0.0'],
      );
      expect(calls[1], contains('v1.0.0'));
    });

    test('prefers dereferenced commit SHA over tag-object SHA', () async {
      final runner = fakeRunner(sha: 'commit-sha-real');
      await runSync(runner: runner);
      calls.clear();

      // Second sync — the stamp holds the commit SHA from the ^{} line,
      // so ls-remote returning it again means up-to-date.
      final code = await runSync(runner: runner);
      expect(code, ExitCode.success.code);
      expect(calls, hasLength(1));
      verify(
        () => progress.complete(any(that: contains('up to date'))),
      ).called(1);
    });
  });

  group('emb boards remove', () {
    final err = <String>[];

    setUp(() {
      when(() => logger.err(any())).thenAnswer((i) {
        err.add('${i.positionalArguments.first}');
      });
      err.clear();
    });

    Future<int> runRemove(List<String> args) async {
      Directory(p.join(tmp.path, 'config', 'emb'))
          .createSync(recursive: true);
      final runner = CommandRunner<int>('emb', 'test')
        ..addCommand(
          BoardsCommand(
            logger: logger,
            environment: {
              'HOME': tmp.path,
              'XDG_CONFIG_HOME': p.join(tmp.path, 'config'),
            },
          ),
        );
      return await runner.run(['boards', 'remove', ...args]) ?? 0;
    }

    test('rejects names with path-traversal characters', () async {
      final code = await runRemove(['../escape']);
      expect(code, ExitCode.usage.code);
      expect(err.join(), contains('Invalid source name'));
    });
  });
}
