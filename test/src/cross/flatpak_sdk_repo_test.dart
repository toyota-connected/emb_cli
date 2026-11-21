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

  FlatpakSdkRepo cache({bool offline = false}) => FlatpakSdkRepo(
    Directory(p.join(tmp.path, 'cache')),
    runProcess: defaultProcessRunner,
    offline: offline,
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

    test('pulls a repo by URL', () async {
      final src = sourceRepo('src');
      final c = await cache().checkout('file://$src', _ref);
      expect(File(p.join(c.path, 'metadata')).existsSync(), isTrue);
    });
  });

  test('a signing key turns on verification for that remote', () async {
    // A fake: what matters is which flags reach ostree.
    final calls = <List<String>>[];
    Future<RunResult> run(
      String exe,
      List<String> args, {
      String? workingDirectory,
      Map<String, String>? environment,
      bool includeParentEnvironment = true,
      bool runInShell = false,
      ProcessOutputMode output = ProcessOutputMode.capture,
      String? label,
    }) async {
      calls.add(args);
      if (args.contains('checkout')) Directory(args.last).createSync();
      return args.contains('rev-parse')
          ? RunResult(0, '${'a' * 64}\n', '')
          : const RunResult(0, '', '');
    }

    final repo = FlatpakSdkRepo(
      Directory(p.join(tmp.path, 'cache')),
      runProcess: run,
    );
    await repo.checkout('https://example.com/repo', _ref, gpgKey: '/k.gpg');
    await repo.checkout('/srv/repo', _ref, gpgKey: '/k.gpg');
    final adds = calls.where((c) => c.contains('add'));
    expect(adds, everyElement(contains('--gpg-import=/k.gpg')));
    expect(adds, everyElement(isNot(contains('--no-gpg-verify'))));
    final pullLocal = calls.singleWhere((c) => c.contains('pull-local'));
    expect(pullLocal, contains('--gpg-verify'));
  });
}
