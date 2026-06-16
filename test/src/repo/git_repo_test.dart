import 'dart:io';

import 'package:emb_cli/src/manifest/source_repo.dart';
import 'package:emb_cli/src/repo/git_repo.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Records git invocations and returns a configurable exit code.
class _FakeGit {
  final List<List<String>> calls = [];
  int Function(List<String> args)? exitFor;

  Future<ProcessResult> run(
    List<String> args, {
    required String workingDirectory,
  }) async {
    calls.add(args);
    final code = exitFor?.call(args) ?? 0;
    return ProcessResult(0, code, '', '');
  }
}

void main() {
  group('folderName', () {
    test('strips trailing .git from the uri basename', () {
      expect(
        const GitRepo(
          uri: 'https://github.com/flutter/super_dash.git',
        ).folderName,
        'super_dash',
      );
    });

    test('honors an explicit destName', () {
      expect(
        const GitRepo(
          uri: 'https://github.com/flutter/samples.git',
          destName: 'flutter-samples',
        ).folderName,
        'flutter-samples',
      );
    });

    test('derives from SourceRepo', () {
      final r = GitRepo.fromSource(
        SourceRepo.fromMap({'uri': 'https://x/y/weston.git', 'branch': '13.0'}),
      );
      expect(r.folderName, 'weston');
      expect(r.branch, '13.0');
    });
  });

  group('sync', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('emb_git_'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test('clones when the folder is absent, then checks out branch', () async {
      final git = _FakeGit();
      const repo = GitRepo(uri: 'https://x/y/foo.git', branch: 'main');
      final result = await repo.sync(tmp, runner: git.run);

      expect(result.success, isTrue);
      expect(git.calls.first, [
        'clone',
        'https://x/y/foo.git',
        'foo',
        '-b',
        'main',
      ]);
      expect(git.calls, contains(equals(['checkout', 'main'])));
    });

    test('updates in place when .git exists', () async {
      // Pre-create <tmp>/foo/.git so the update path is taken.
      Directory(p.join(tmp.path, 'foo', '.git')).createSync(recursive: true);
      final git = _FakeGit();
      const repo = GitRepo(uri: 'https://x/y/foo.git', branch: 'dev');
      await repo.sync(tmp, runner: git.run);

      expect(git.calls, contains(equals(['reset', '--hard'])));
      expect(git.calls, contains(equals(['fetch', '--all'])));
      expect(
        git.calls,
        contains(equals(['pull', '--ff-only', 'origin', 'dev'])),
      );
      expect(git.calls, contains(equals(['checkout', 'dev'])));
      // No clone on the update path.
      expect(git.calls.any((c) => c.first == 'clone'), isFalse);
    });

    test('reports failure when clone fails', () async {
      final git = _FakeGit()..exitFor = (a) => a.first == 'clone' ? 1 : 0;
      const repo = GitRepo(uri: 'https://x/y/foo.git');
      final result = await repo.sync(tmp, runner: git.run);
      expect(result.success, isFalse);
      expect(result.message, contains('clone'));
    });

    test('checks out an explicit rev over the branch', () async {
      final git = _FakeGit();
      const repo = GitRepo(
        uri: 'https://x/y/foo.git',
        branch: 'main',
        rev: 'abc123',
      );
      await repo.sync(tmp, runner: git.run);
      expect(git.calls, contains(equals(['checkout', 'abc123'])));
      expect(git.calls, isNot(contains(equals(['checkout', 'main']))));
    });
  });
}
