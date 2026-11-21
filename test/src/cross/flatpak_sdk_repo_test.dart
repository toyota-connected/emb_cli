import 'dart:io';

import 'package:emb_cli/src/cross/flatpak_sdk_repo.dart';
import 'package:emb_cli/src/cross/process_runner.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Real `ostree`, when the host has it: the commands and their output are the
/// contract here, and a fake would only restate this file's assumptions.
final bool _haveOstree = () {
  try {
    return Process.runSync('ostree', ['--version']).exitCode == 0;
  } on ProcessException {
    return false;
  }
}();

const _ref = 'runtime/org.test.Sdk/x86_64/1';

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('emb_fpsdk_repo_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  /// An archive repo, as flatpak tooling writes them, with [ref] committed
  /// holding a metadata file that says [marker].
  String sourceRepo(String name, {String ref = _ref, String marker = 'a'}) {
    final repo = p.join(tmp.path, name);
    if (!Directory(repo).existsSync()) {
      Process.runSync('ostree', ['init', '--repo=$repo', '--mode=archive-z2']);
    }
    final tree = Directory(p.join(tmp.path, '$name-tree-$marker'))
      ..createSync(recursive: true);
    File(
      p.join(tree.path, 'metadata'),
    ).writeAsStringSync('[Runtime]\n#$marker\n');
    File(
      p.join(tree.path, 'files', 'lib', 'libc.so.6'),
    ).createSync(recursive: true);
    final r = Process.runSync('ostree', [
      'commit',
      '--repo=$repo',
      '--branch=$ref',
      '--subject=test',
      tree.path,
    ]);
    expect(r.exitCode, 0, reason: '${r.stderr}');
    return repo;
  }

  FlatpakSdkRepo cache({
    bool offline = false,
    Duration pullTimeout = FlatpakSdkRepo.defaultPullTimeout,
  }) => FlatpakSdkRepo(
    Directory(p.join(tmp.path, 'cache')),
    runProcess: defaultTimedProcessRunner,
    offline: offline,
    pullTimeout: pullTimeout,
  );

  group('with ostree', skip: _haveOstree ? false : 'ostree not installed', () {
    test('checks a ref out of a local repo, by commit', () async {
      final c = await cache().checkout(sourceRepo('src'), _ref);
      expect(c.commit, matches(RegExp(r'^[0-9a-f]{64}$')));
      expect(p.basename(c.path), c.commit);
      expect(
        File(p.join(c.path, 'metadata')).readAsStringSync(),
        contains('#a'),
      );
      expect(File(p.join(c.path, 'files/lib/libc.so.6')).existsSync(), isTrue);
    });

    test('reuses the checkout while the commit is unchanged', () async {
      final src = sourceRepo('src');
      final a = await cache().checkout(src, _ref);
      final stamp = File(p.join(a.path, 'stamp'))..writeAsStringSync('x');
      final b = await cache().checkout(src, _ref);
      expect(b.path, a.path);
      expect(stamp.existsSync(), isTrue);
    });

    test('follows the repo to a new commit', () async {
      final src = sourceRepo('src');
      final a = await cache().checkout(src, _ref);
      sourceRepo('src', marker: 'b');
      final b = await cache().checkout(src, _ref);
      expect(b.commit, isNot(a.commit));
      expect(
        File(p.join(b.path, 'metadata')).readAsStringSync(),
        contains('#b'),
      );
    });

    test('keeps two repos with the same ref apart', () async {
      final one = sourceRepo('one');
      final two = sourceRepo('two', marker: 'b');
      final a = await cache().checkout(one, _ref);
      final b = await cache().checkout(two, _ref);
      expect(b.commit, isNot(a.commit));
      // Offline, each source reads back its own ref, not the last pulled.
      final again = await cache(offline: true).checkout(one, _ref);
      expect(again.commit, a.commit);
    });

    test('two concurrent checkouts of one commit both succeed', () async {
      final src = sourceRepo('src');
      final results = await Future.wait([
        cache().checkout(src, _ref),
        cache().checkout(src, _ref),
        cache().checkout(src, _ref),
      ]);
      expect(results.map((c) => c.path).toSet(), hasLength(1));
      expect(
        Directory(
          p.join(tmp.path, 'cache', 'checkouts'),
        ).listSync().map((e) => p.basename(e.path)),
        [results.first.commit],
      );
    });

    test('offline uses the cache and pulls nothing', () async {
      final src = sourceRepo('src');
      final a = await cache().checkout(src, _ref);
      sourceRepo('src', marker: 'b'); // a newer commit it must not see
      final b = await cache(offline: true).checkout(src, _ref);
      expect(b.commit, a.commit);
    });

    test('offline with nothing cached says to fetch', () async {
      await expectLater(
        cache(offline: true).checkout(sourceRepo('src'), _ref),
        throwsA(
          isA<FlatpakSdkRepoException>().having(
            (e) => e.message,
            'message',
            contains('Run `emb fetch` online first'),
          ),
        ),
      );
    });

    test('names a ref the repo does not have', () async {
      await expectLater(
        cache().checkout(sourceRepo('src'), 'runtime/org.test.Nope/x86_64/1'),
        throwsA(
          isA<FlatpakSdkRepoException>().having(
            (e) => e.message,
            'message',
            contains('could not pull runtime/org.test.Nope/x86_64/1'),
          ),
        ),
      );
    });

    test('a source gone missing falls back to its cached commit', () async {
      final src = sourceRepo('src');
      final first = await cache().checkout(src, _ref);
      Directory(src).deleteSync(recursive: true);
      final again = await cache().checkout(src, _ref);
      expect(again.commit, first.commit);
      expect(again.path, first.path);
      expect(again.warning, contains('cached commit'));
    });

    test('a pull over its limit is killed, and the cache used', () async {
      final src = sourceRepo('src');
      final first = await cache().checkout(src, _ref);
      // A pull that cannot finish: opening a FIFO blocks until a writer comes,
      // and none will. A short limit alone races a pull with nothing new.
      final config = p.join(src, 'config');
      File(config).deleteSync();
      expect(Process.runSync('mkfifo', [config]).exitCode, 0);
      final sw = Stopwatch()..start();
      final again = await cache(
        pullTimeout: const Duration(seconds: 1),
      ).checkout(src, _ref);
      expect(again.commit, first.commit);
      expect(again.warning, contains('(timed out after 1 s)'));
      expect(sw.elapsed, lessThan(const Duration(seconds: 20)));
    });

    test('pulls a repo by URL', () async {
      final src = sourceRepo('src');
      final c = await cache().checkout('file://$src', _ref);
      expect(File(p.join(c.path, 'metadata')).existsSync(), isTrue);
    });
  });

  /// A fake ostree recording its argv; what matters is which flags reach it.
  /// [pull] is what a pull returns; [cached] is whether rev-parse finds the
  /// ref. [timeouts] records the limit each call was given.
  TimedProcessRunner fakeOstree(
    List<List<String>> calls, {
    RunResult pull = const RunResult(0, '', ''),
    bool cached = true,
    List<Duration?>? timeouts,
  }) {
    return (
      exe,
      args, {
      workingDirectory,
      environment,
      includeParentEnvironment = true,
      runInShell = false,
      output = ProcessOutputMode.capture,
      label,
      timeout,
    }) async {
      calls.add(args);
      timeouts?.add(timeout);
      if (args.contains('checkout')) Directory(args.last).createSync();
      if (args.contains('pull') || args.contains('pull-local')) return pull;
      if (args.contains('rev-parse')) {
        return cached
            ? RunResult(0, '${'a' * 64}\n', '')
            : const RunResult(1, '', 'error: Refspec not found');
      }
      return const RunResult(0, '', '');
    };
  }

  group('a pull that fails', () {
    FlatpakSdkRepo repo(TimedProcessRunner run) =>
        FlatpakSdkRepo(Directory(p.join(tmp.path, 'cache')), runProcess: run);

    test('falls back to the cached commit, with a warning', () async {
      final c = await repo(
        fakeOstree(
          [],
          pull: const RunResult(1, '', 'error: Could not resolve host\nmore'),
        ),
      ).checkout('https://example.com/repo', _ref);
      expect(c.commit, 'a' * 64);
      expect(
        c.warning,
        allOf(
          contains('could not pull $_ref from https://example.com/repo'),
          contains('(error: Could not resolve host)'),
          contains('cached commit aaaaaaaaaaaa'),
        ),
      );
    });

    test('with nothing cached is an error', () async {
      await expectLater(
        repo(
          fakeOstree(
            [],
            pull: const RunResult(1, '', 'error: Could not resolve host'),
            cached: false,
          ),
        ).checkout('https://example.com/repo', _ref),
        throwsA(
          isA<FlatpakSdkRepoException>().having(
            (e) => e.message,
            'message',
            'could not pull $_ref from https://example.com/repo: '
                'error: Could not resolve host',
          ),
        ),
      );
    });

    test('says when it timed out', () async {
      final c = await repo(
        fakeOstree(
          [],
          pull: const RunResult(timedOutExitCode, '', 'timed out after 1800s'),
        ),
      ).checkout('/srv/repo', _ref);
      expect(c.warning, contains('(timed out after 30 min)'));
    });
  });

  test('only the pull has a time limit', () async {
    final calls = <List<String>>[];
    final timeouts = <Duration?>[];
    await FlatpakSdkRepo(
      Directory(p.join(tmp.path, 'cache')),
      runProcess: fakeOstree(calls, timeouts: timeouts),
    ).checkout('https://example.com/repo', _ref);
    for (final (i, c) in calls.indexed) {
      expect(
        timeouts[i],
        c.contains('pull') ? FlatpakSdkRepo.defaultPullTimeout : isNull,
        reason: c.join(' '),
      );
    }
    expect(calls.where((c) => c.contains('pull')), hasLength(1));
  });

  test('a successful pull carries no warning', () async {
    final c = await FlatpakSdkRepo(
      Directory(p.join(tmp.path, 'cache')),
      runProcess: fakeOstree([]),
    ).checkout('https://example.com/repo', _ref);
    expect(c.warning, isNull);
  });

  test('a signing key turns on verification for that remote', () async {
    final calls = <List<String>>[];
    final key = File(p.join(tmp.path, 'k.gpg'))..writeAsStringSync('key one');
    final repo = FlatpakSdkRepo(
      Directory(p.join(tmp.path, 'cache')),
      runProcess: fakeOstree(calls),
    );
    await repo.checkout('https://example.com/repo', _ref, gpgKey: key.path);
    await repo.checkout('/srv/repo', _ref, gpgKey: key.path);
    final adds = calls.where((c) => c.contains('add'));
    expect(adds, everyElement(contains('--gpg-import=${key.path}')));
    expect(adds, everyElement(isNot(contains('--no-gpg-verify'))));
    final pullLocal = calls.singleWhere((c) => c.contains('pull-local'));
    expect(pullLocal, contains('--gpg-verify'));
  });

  test('a key rotated in place gets a remote of its own', () async {
    // The key is imported only when a remote is created, so the old keyring
    // must not go on judging commits after the file changes.
    final calls = <List<String>>[];
    final key = File(p.join(tmp.path, 'k.gpg'))..writeAsStringSync('key one');
    final repo = FlatpakSdkRepo(
      Directory(p.join(tmp.path, 'cache')),
      runProcess: fakeOstree(calls),
    );
    await repo.checkout('https://example.com/repo', _ref, gpgKey: key.path);
    key.writeAsStringSync('key two');
    await repo.checkout('https://example.com/repo', _ref, gpgKey: key.path);
    final names = calls
        .where((c) => c.contains('add'))
        .map((c) => c[c.length - 2])
        .toSet();
    expect(names, hasLength(2));
  });

  test('an unreadable key is an error, not an unverified pull', () async {
    await expectLater(
      FlatpakSdkRepo(
        Directory(p.join(tmp.path, 'cache')),
        runProcess: fakeOstree([]),
      ).checkout('https://example.com/repo', _ref, gpgKey: '/no/such.gpg'),
      throwsA(
        isA<FlatpakSdkRepoException>().having(
          (e) => e.message,
          'message',
          contains('cannot read sdk_repo_gpg_key /no/such.gpg'),
        ),
      ),
    );
  });

  test('clears checkouts a killed run left, but not one in progress', () async {
    final commit = 'a' * 64;
    final checkouts = Directory(p.join(tmp.path, 'cache', 'checkouts'))
      ..createSync(recursive: true);
    // A pid that has exited, so nothing owns its partial any more.
    final dead = Process.runSync('true', const []).pid;
    final stale = Directory(p.join(checkouts.path, '$commit.partial-$dead-0'))
      ..createSync();
    // A live process's, whatever its mtime: ostree stamps checkouts with the
    // epoch, so age says nothing about whether it is still being written.
    final live = Directory(p.join(checkouts.path, '$commit.partial-1-0'))
      ..createSync();
    Process.runSync('touch', ['-d', '@0', live.path]);
    await FlatpakSdkRepo(
      Directory(p.join(tmp.path, 'cache')),
      runProcess: fakeOstree([]),
    ).checkout('/srv/repo', _ref);
    expect(stale.existsSync(), isFalse);
    expect(live.existsSync(), isTrue);
  });
}
