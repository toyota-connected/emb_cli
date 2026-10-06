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

  group('makeTimedProcessRunner', () {
    final run = makeTimedProcessRunner();

    // A duration no other process plausibly sleeps for, so the check below
    // finds this test's own child and nothing else. Counting `sleep`
    // processes, or diffing the set of them, both read the whole machine's
    // process table — this suite runs its files concurrently and does not own
    // it, so an unrelated `sleep` appearing or exiting mid-test moved either
    // answer.
    const sentinel = '31337';

    /// Whether this test's own `sleep` is still running.
    Future<bool> childAlive() async {
      final r = await Process.run('pgrep', ['-fx', 'sleep $sentinel']);
      return r.exitCode == 0;
    }

    test('kills the child and reports the limit', () async {
      final sw = Stopwatch()..start();
      final r = await run('sleep', const [
        sentinel,
      ], timeout: const Duration(seconds: 1));
      sw.stop();

      expect(r.exitCode, timedOutExitCode);
      expect(r.stderr, contains('timed out after 1s'));
      expect(r.stderr, contains('sleep $sentinel'));
      // It returned on the limit, not after the sleep.
      expect(sw.elapsed, lessThan(const Duration(seconds: 10)));
      // And the child is gone: a `.timeout()` on the future would have left it
      // running, which is why the limit lives in the runner.
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(
        await childAlive(),
        isFalse,
        reason: 'the timed-out child is still running',
      );
    });

    test('escalates to SIGKILL when SIGTERM is ignored', () async {
      // A child that ignores SIGTERM, written in Dart rather than as
      // `sh -c 'trap "" TERM; …'`: whether a shell traps or execs through
      // depends on which /bin/sh the host has, so the shell version asserted
      // nothing reliable — it passed locally while timing out on CI.
      final dir = Directory.systemTemp.createTempSync('emb_sigterm_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final child = File(p.join(dir.path, 'stubborn.dart'))
        ..writeAsStringSync(
          [
            "import 'dart:async';",
            "import 'dart:io';",
            'void main() {',
            '  ProcessSignal.sigterm.watch().listen((_) {});',
            '  Timer(const Duration(seconds: 60), () {});',
            '}',
          ].join('\n'),
        );

      final stubborn = makeTimedProcessRunner(
        graceOnTimeout: const Duration(seconds: 1),
      );
      final sw = Stopwatch()..start();
      final r = await stubborn(Platform.resolvedExecutable, [
        'run',
        child.path,
      ], timeout: const Duration(seconds: 3));
      sw.stop();

      expect(r.exitCode, timedOutExitCode);
      // It outlived SIGTERM (so at least the limit) and died on SIGKILL rather
      // than running its full 60 seconds.
      expect(sw.elapsed, greaterThanOrEqualTo(const Duration(seconds: 3)));
      expect(sw.elapsed, lessThan(const Duration(seconds: 30)));
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('a run inside its limit is untouched', () async {
      final r = await run('echo', [
        'hello',
      ], timeout: const Duration(seconds: 30));
      expect(r.exitCode, 0);
      expect(r.stdout.trim(), 'hello');
      expect(r.stderr, isEmpty);
    });

    test('no limit means no limit', () async {
      final r = await run('echo', ['hi']);
      expect(r.exitCode, 0);
      expect(r.stdout.trim(), 'hi');
    });

    test('a non-zero exit is reported as itself, not as a timeout', () async {
      final r = await run('sh', [
        '-c',
        'echo oops >&2; exit 3',
      ], timeout: const Duration(seconds: 30));
      expect(r.exitCode, 3);
      expect(r.stderr.trim(), 'oops');
    });
  });
}
