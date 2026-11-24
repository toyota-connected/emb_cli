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

final bool _haveGpg = () {
  try {
    return Process.runSync('gpg', ['--version']).exitCode == 0;
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

    group('signed by sdk_repo_gpg_key', skip: _haveGpg ? false : 'no gpg', () {
      late String home;
      late String fpr;
      late String key;

      setUp(() {
        home = p.join(tmp.path, 'gnupg');
        Directory(home).createSync();
        Process.runSync('chmod', ['700', home]);
        final gen = Process.runSync('gpg', [
          '--homedir=$home',
          '--batch',
          '--passphrase=',
          '--quick-gen-key',
          'emb test <test@example.invalid>',
          'ed25519',
          'sign',
          'never',
        ]);
        expect(gen.exitCode, 0, reason: '${gen.stderr}');
        final list = Process.runSync('gpg', [
          '--homedir=$home',
          '--with-colons',
          '--list-keys',
        ]);
        fpr = RegExp(
          '^fpr:+([0-9A-F]+):',
          multiLine: true,
        ).firstMatch('${list.stdout}')![1]!;
        key = p.join(tmp.path, 'key.gpg');
        final export = Process.runSync('gpg', [
          '--homedir=$home',
          '--export',
          '--output=$key',
          fpr,
        ]);
        expect(export.exitCode, 0, reason: '${export.stderr}');
      });
      tearDown(
        () => Process.runSync('gpgconf', [
          '--homedir=$home',
          '--kill',
          'gpg-agent',
        ]),
      );

      /// [sourceRepo], its commit signed and dated [date], and its summary
      /// signed when [signSummary].
      String signedRepo({
        String marker = 'a',
        String date = '2025-01-02',
        bool signSummary = true,
      }) {
        final repo = p.join(tmp.path, 'signed');
        if (!Directory(repo).existsSync()) {
          Process.runSync('ostree', [
            'init',
            '--repo=$repo',
            '--mode=archive-z2',
          ]);
        }
        final tree = Directory(p.join(tmp.path, 'signed-tree-$marker'))
          ..createSync(recursive: true);
        File(p.join(tree.path, 'metadata')).writeAsStringSync('#$marker\n');
        final commit = Process.runSync('ostree', [
          'commit',
          '--repo=$repo',
          '--branch=$_ref',
          '--timestamp=$date',
          '--gpg-sign=$fpr',
          '--gpg-homedir=$home',
          tree.path,
        ]);
        expect(commit.exitCode, 0, reason: '${commit.stderr}');
        final summary = Process.runSync('ostree', [
          'summary',
          '--repo=$repo',
          '-u',
          if (signSummary) ...['--gpg-sign=$fpr', '--gpg-homedir=$home'],
        ]);
        expect(summary.exitCode, 0, reason: '${summary.stderr}');
        return repo;
      }

      Matcher refused(String text) => throwsA(
        isA<FlatpakSdkRepoException>().having(
          (e) => e.message,
          'message',
          contains(text),
        ),
      );

      for (final url in [false, true]) {
        final how = url ? 'by URL' : 'by path';

        test('commits and summary signed: checks out, $how', () async {
          final src = signedRepo();
          final c = await cache().checkout(
            url ? 'file://$src' : src,
            _ref,
            gpgKey: key,
          );
          expect(
            File(p.join(c.path, 'metadata')).readAsStringSync(),
            '#a\n',
          );
        });

        // Even with a good commit cached: the cache would hide it for good.
        test('an unsigned summary is refused, not ridden out, $how', () async {
          final src = signedRepo();
          final source = url ? 'file://$src' : src;
          await cache().checkout(source, _ref, gpgKey: key);
          signedRepo(marker: 'b', date: '2025-02-02', signSummary: false);
          await expectLater(
            cache().checkout(source, _ref, gpgKey: key),
            refused('has no summary signed by sdk_repo_gpg_key'),
          );
        });
      }

      test('a URL that moves the ref back in time is refused', () async {
        final src = signedRepo();
        await cache().checkout('file://$src', _ref, gpgKey: key);
        // Signed by the key, so commit signatures alone would pass it.
        signedRepo(marker: 'old', date: '2024-01-02');
        await expectLater(
          cache().checkout('file://$src', _ref, gpgKey: key),
          refused('refusing the rollback'),
        );
      });

      test('a commit signed by another key is refused', () async {
        final src = signedRepo();
        final other = File(p.join(tmp.path, 'other.gpg'));
        // A key file of the right shape, holding someone else's key.
        final home2 = p.join(tmp.path, 'gnupg2');
        Directory(home2).createSync();
        Process.runSync('chmod', ['700', home2]);
        Process.runSync('gpg', [
          '--homedir=$home2',
          '--batch',
          '--passphrase=',
          '--quick-gen-key',
          'other <other@example.invalid>',
          'ed25519',
          'sign',
          'never',
        ]);
        Process.runSync('gpg', [
          '--homedir=$home2',
          '--export',
          '--output=${other.path}',
        ]);
        addTearDown(
          () => Process.runSync('gpgconf', [
            '--homedir=$home2',
            '--kill',
            'gpg-agent',
          ]),
        );
        await expectLater(
          cache().checkout(src, _ref, gpgKey: other.path),
          refused('not signed by sdk_repo_gpg_key'),
        );
      });

      // A cache from before summaries were checked keeps its remote, and so
      // what --offline can build from, and gains the check.
      test('a remote added without the summary check gains it', () async {
        final src = signedRepo();
        final c = cache();
        await c.checkout(src, _ref, gpgKey: key);
        final repo = p.join(tmp.path, 'cache', 'repo');
        final config = File(p.join(repo, 'config'));
        config.writeAsStringSync(
          config.readAsStringSync().replaceAll(
            'gpg-verify-summary=true',
            'gpg-verify-summary=false',
          ),
        );
        signedRepo(marker: 'b', date: '2025-02-02', signSummary: false);
        await expectLater(
          c.checkout(src, _ref, gpgKey: key),
          refused('has no summary signed by sdk_repo_gpg_key'),
        );
        expect(config.readAsStringSync(), contains('gpg-verify-summary=true'));
        expect(
          config.readAsStringSync(),
          isNot(contains('gpg-verify-summary=false')),
        );
      });
    });

    // #369: remote setup rewrites repo/config, and concurrent builds of
    // different sources used to race on it.
    //
    // 72 first checkouts take some 5 s on a 32-core machine and over 30 on
    // a 4-core CI runner, where the default timeout failed it (#387). The
    // timeout fails the test while its checkouts run on, and tearDown then
    // deletes the cache under them: the "Rename failed" that followed was
    // that, not a race in _checkoutCommit.
    test(
      'concurrent first checkouts of different sources keep every remote',
      () async {
        // A race, so several rounds: one lost a remote about one time in
        // three before the fix.
        const n = 24;
        for (var round = 0; round < 3; round++) {
          // Each with content of its own, so each is a commit of its own,
          // as different SDKs are.
          final sources = [
            for (var i = 0; i < n; i++)
              sourceRepo('r$round-src$i', marker: 'r$round-src$i'),
          ];
          await Future.wait([
            for (final s in sources) cache().checkout(s, _ref),
          ]);
          final remotes = Process.runSync('ostree', [
            '--repo=${p.join(tmp.path, 'cache', 'repo')}',
            'remote',
            'list',
          ]);
          expect(
            '${remotes.stdout}'.trim().split('\n').where((l) => l.isNotEmpty),
            hasLength(n * (round + 1)),
            reason: 'round $round',
          );
        }
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );

    group('gc', () {
      File used(String commit) =>
          File(p.join(tmp.path, 'cache', 'used', commit));
      Directory checkoutOf(String commit) =>
          Directory(p.join(tmp.path, 'cache', 'checkouts', commit));
      void age(String commit, {int days = 8}) => used(commit).writeAsStringSync(
        DateTime.now().toUtc().subtract(Duration(days: days)).toIso8601String(),
      );
      String refs() =>
          Process.runSync('ostree', [
                '--repo=${p.join(tmp.path, 'cache', 'repo')}',
                'refs',
              ]).stdout
              as String;

      test('keeps what a build used this week', () async {
        final c = await cache().checkout(sourceRepo('src'), _ref);
        expect(used(c.commit).existsSync(), isTrue);
        final r = await cache().gc();
        expect(r.removed, isEmpty);
        expect(checkoutOf(c.commit).existsSync(), isTrue);
        expect(refs(), contains(_ref));
      });

      test('drops an SDK unused for a week, objects too', () async {
        final src = sourceRepo('src');
        final c = await cache().checkout(src, _ref);
        age(c.commit);
        final r = await cache().gc();
        expect(r.removed, [
          'flatpak-sdk ref $_ref ($src)',
          'flatpak-sdk checkout ${c.commit.substring(0, 12)}',
        ]);
        expect(r.objects, startsWith('Deleted '));
        expect(checkoutOf(c.commit).existsSync(), isFalse);
        expect(used(c.commit).existsSync(), isFalse);
        expect(refs(), isNot(contains(_ref)));
        // The next build pulls it again.
        final again = await cache().checkout(src, _ref);
        expect(again.commit, c.commit);
      });

      test("an update's old commit goes, the new one stays", () async {
        final src = sourceRepo('src');
        final old = await cache().checkout(src, _ref);
        sourceRepo('src', marker: 'b');
        final cur = await cache().checkout(src, _ref);
        expect(cur.commit, isNot(old.commit));
        age(old.commit);
        final r = await cache().gc();
        expect(r.removed, [
          'flatpak-sdk checkout ${old.commit.substring(0, 12)}',
        ]);
        expect(r.objects, startsWith('Deleted '));
        expect(checkoutOf(cur.commit).existsSync(), isTrue);
        expect(refs(), contains(_ref));
      });

      test('--dry-run changes nothing', () async {
        final c = await cache().checkout(sourceRepo('src'), _ref);
        age(c.commit);
        final r = await cache().gc(dryRun: true);
        expect(r.removed, hasLength(2));
        expect(r.objects, isNot(startsWith('Deleted')));
        expect(checkoutOf(c.commit).existsSync(), isTrue);
        expect(refs(), contains(_ref));
      });

      test(
        'an SDK from before uses were recorded is kept, and recorded',
        () async {
          final c = await cache().checkout(sourceRepo('src'), _ref);
          Directory(p.join(tmp.path, 'cache', 'used')).deleteSync(
            recursive: true,
          );
          expect((await cache().gc()).removed, isEmpty);
          expect(used(c.commit).existsSync(), isTrue);
        },
      );

      test("drops a dead run's partial checkout", () async {
        await cache().checkout(sourceRepo('src'), _ref);
        final dead = Process.runSync('true', const []).pid;
        final partial = Directory(
          p.join(tmp.path, 'cache', 'checkouts', '${'b' * 64}.partial-$dead-0'),
        )..createSync();
        final r = await cache().gc();
        expect(r.removed, ['flatpak-sdk checkout ${'b' * 12}']);
        expect(partial.existsSync(), isFalse);
      });
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

  test('gc with no repo runs nothing', () async {
    final calls = <List<String>>[];
    final r = await FlatpakSdkRepo(
      Directory(p.join(tmp.path, 'cache')),
      runProcess: fakeOstree(calls),
    ).gc();
    expect(r.removed, isEmpty);
    expect(r.objects, isNull);
    expect(calls, isEmpty);
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
    expect(pullLocal, containsAll(['--gpg-verify', '--gpg-verify-summary']));
    expect(adds, everyElement(contains('--set=gpg-verify-summary=true')));
    final pull = calls.singleWhere((c) => c.contains('pull'));
    expect(pull, contains('--timestamp-check'));
  });

  test('without a key, nothing is verified and nothing checked', () async {
    final calls = <List<String>>[];
    final repo = FlatpakSdkRepo(
      Directory(p.join(tmp.path, 'cache')),
      runProcess: fakeOstree(calls),
    );
    await repo.checkout('https://example.com/repo', _ref);
    await repo.checkout('/srv/repo', _ref);
    final flags = calls.expand((c) => c);
    expect(flags, contains('--no-gpg-verify'));
    for (final f in [
      '--gpg-verify',
      '--gpg-verify-summary',
      '--set=gpg-verify-summary=true',
      '--timestamp-check',
    ]) {
      expect(flags, isNot(contains(f)));
    }
    expect(calls.where((c) => c.contains('config')), isEmpty);
  });

  group('a verification failure is not ridden out on the cache', () {
    const failures = {
      'error: GPG verification enabled, but no summary.sig found (use '
              'gpg-verify-summary=false in remote config to disable)':
          'has no summary signed by sdk_repo_gpg_key',
      'error: GPG verification enabled, but no summary found':
          'has no summary signed by sdk_repo_gpg_key',
      "error: Upgrade target revision 'b' with timestamp 'x' is "
              "chronologically older than current revision 'a'":
          'refusing the rollback',
      'error: GPG signatures found, but none are in trusted keyring':
          'is not signed by sdk_repo_gpg_key: error: GPG signatures found',
    };
    for (final f in failures.entries) {
      test(f.value, () async {
        final key = File(p.join(tmp.path, 'k.gpg'))..writeAsStringSync('k');
        await expectLater(
          FlatpakSdkRepo(
            Directory(p.join(tmp.path, 'cache')),
            runProcess: fakeOstree([], pull: RunResult(1, '', f.key)),
          ).checkout('https://example.com/repo', _ref, gpgKey: key.path),
          throwsA(
            isA<FlatpakSdkRepoException>().having(
              (e) => e.message,
              'message',
              contains(f.value),
            ),
          ),
        );
      });
    }
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
