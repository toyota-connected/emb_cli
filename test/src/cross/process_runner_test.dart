import 'dart:io';

import 'package:emb_cli/src/cross/process_runner.dart';
import 'package:emb_cli/src/verbosity.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test('defaultProcessRunner forwards to Process.run', () async {
    final ok = await defaultProcessRunner('sh', ['-c', 'exit 0']);
    expect(ok.exitCode, 0);

    final bad = await defaultProcessRunner('sh', ['-c', 'exit 3']);
    expect(bad.exitCode, 3);
  });

  test('defaultProcessRunner passes the environment through', () async {
    final r = await defaultProcessRunner(
      'sh',
      ['-c', r'printf %s "$EMB_T"'],
      environment: {'EMB_T': 'hi'},
    );
    expect(r.stdout, 'hi');
  });

  group('stream mode', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('emb_pr_'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test('tees prefixed lines live at -v and retains the output', () async {
      final log = File(p.join(tmp.path, 'tee.log'));
      final sink = log.openWrite();
      final run = makeProcessRunner(
        verbosity: Verbosity.verbose,
        out: sink,
        err: sink,
      );
      final r = await run(
        'sh',
        ['-c', 'echo hello; echo oops >&2'],
        output: ProcessOutputMode.stream,
        label: 'demo',
      );
      await sink.flush();
      await sink.close();

      expect(r.exitCode, 0);
      expect(r.stdout, contains('hello'));
      expect(r.stderr, contains('oops'));
      final teed = log.readAsStringSync();
      expect(teed, contains('[demo] hello'));
      expect(teed, contains('[demo] oops'));
    });

    test('captures silently at normal verbosity', () async {
      final log = File(p.join(tmp.path, 'tee.log'));
      final sink = log.openWrite();
      final run = makeProcessRunner(
        verbosity: Verbosity.normal,
        out: sink,
        err: sink,
      );
      final r = await run(
        'sh',
        ['-c', 'echo hello'],
        output: ProcessOutputMode.stream,
        label: 'demo',
      );
      await sink.flush();
      await sink.close();

      // The output is retained for diagnostics but nothing is teed live.
      expect(r.stdout, contains('hello'));
      expect(log.readAsStringSync(), isEmpty);
    });

    test('bounds the retained tail to the most recent lines', () async {
      final run = makeProcessRunner(verbosity: Verbosity.normal);
      final r = await run('sh', [
        '-c',
        r'for i in $(seq 1 300); do echo line$i; done',
      ], output: ProcessOutputMode.stream);
      final lines = r.stdout.split('\n');
      expect(lines.length, lessThanOrEqualTo(200));
      expect(r.stdout, contains('line300'));
      // The earliest lines are dropped once the cap is exceeded.
      expect(r.stdout, isNot(contains('line1\n')));
    });
  });

  group('withEnv', () {
    test('merges extra env (winning) and forwards the other args', () async {
      Map<String, String>? gotEnv;
      String? gotCwd;
      Future<RunResult> inner(
        String exe,
        List<String> args, {
        String? workingDirectory,
        Map<String, String>? environment,
        bool includeParentEnvironment = true,
        bool runInShell = false,
        ProcessOutputMode output = ProcessOutputMode.capture,
        String? label,
      }) async {
        gotEnv = environment;
        gotCwd = workingDirectory;
        return const RunResult(0, '', '');
      }

      final run = withEnv(inner, {'PUB_CACHE': '/store/pub-cache', 'A': '2'});
      await run(
        'flutter',
        const ['pub', 'get'],
        workingDirectory: '/app',
        environment: {'A': '1', 'B': '3'},
      );

      expect(gotEnv, {'A': '2', 'B': '3', 'PUB_CACHE': '/store/pub-cache'});
      expect(gotCwd, '/app');
    });
  });
}
