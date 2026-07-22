import 'dart:io';

import 'package:emb_cli/src/manifest/source_repo.dart';
import 'package:emb_cli/src/repo/git_repo.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Records git invocations and returns a configurable exit code.
class _FakeGit {
  final List<List<String>> calls = [];
  int Function(List<String> args)? exitFor;
  String Function(List<String> args)? stdoutFor;

  Future<ProcessResult> run(
    List<String> args, {
    required String workingDirectory,
  }) async {
    calls.add(args);
    final code = exitFor?.call(args) ?? 0;
    final out = stdoutFor?.call(args) ?? '';
    return ProcessResult(0, code, out, '');
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

    test('creates a missing base directory before cloning', () async {
      // `emb flutter -w /tmp/wksp` clones into a fresh root that doesn't
      // exist yet; sync must create it so `git clone`'s cwd is valid.
      final base = Directory(p.join(tmp.path, 'does', 'not', 'exist'));
      expect(base.existsSync(), isFalse);
      final git = _FakeGit();
      const repo = GitRepo(uri: 'https://x/y/foo.git', branch: 'main');
      final result = await repo.sync(base, runner: git.run);

      expect(result.success, isTrue);
      expect(base.existsSync(), isTrue);
      expect(git.calls.first.first, 'clone');
    });

    test('fails gracefully when the base path cannot be created', () async {
      // A file sits where the base directory needs to be, so the OS-agnostic
      // mkdir -p (createSync) throws — must surface as a failed RepoResult.
      final blocker = File(p.join(tmp.path, 'blocker'))..writeAsStringSync('x');
      final base = Directory(p.join(blocker.path, 'sub'));
      final git = _FakeGit();
      const repo = GitRepo(uri: 'https://x/y/foo.git');
      final result = await repo.sync(base, runner: git.run);

      expect(result.success, isFalse);
      expect(result.message, contains('workspace path unusable'));
      expect(git.calls, isEmpty); // never reached the clone
    });

    test('reports failure (no crash) when git is not runnable', () async {
      // Process.run throws ProcessException when git is absent — must surface
      // as a failed RepoResult, not an unhandled exception.
      Future<ProcessResult> brokenGit(
        List<String> args, {
        required String workingDirectory,
      }) async => throw const ProcessException('git', ['clone']);
      const repo = GitRepo(uri: 'https://x/y/foo.git');
      final result = await repo.sync(tmp, runner: brokenGit);
      expect(result.success, isFalse);
      expect(result.message, contains('git could not be run'));
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

    test('tolerates a failed post-checkout hook when HEAD landed', () async {
      Directory(p.join(tmp.path, 'foo', '.git')).createSync(recursive: true);
      // checkout exits non-zero (hook adopted its status), but HEAD and the
      // requested rev resolve to the same commit -> the checkout succeeded.
      int checkoutFails(List<String> a) => a.first == 'checkout' ? 1 : 0;
      String sameSha(List<String> a) =>
          a.first == 'rev-parse' ? 'cafe1234' : '';
      final git = _FakeGit()
        ..exitFor = checkoutFails
        ..stdoutFor = sameSha;
      const repo = GitRepo(uri: 'https://x/y/foo.git', rev: 'v1');
      final result = await repo.sync(tmp, runner: git.run);

      expect(result.success, isTrue);
      expect(git.calls, contains(equals(['rev-parse', 'HEAD'])));
      expect(git.calls, contains(equals(['rev-parse', 'v1^{commit}'])));
    });

    test('reports failure when checkout does not land on the ref', () async {
      Directory(p.join(tmp.path, 'foo', '.git')).createSync(recursive: true);
      // checkout exits non-zero AND HEAD != ref -> a genuine failure.
      int checkoutFails(List<String> a) => a.first == 'checkout' ? 1 : 0;
      String mismatchedSha(List<String> a) {
        if (a.first != 'rev-parse') return '';
        return a.contains('HEAD') ? 'aaaa' : 'bbbb';
      }

      final git = _FakeGit()
        ..exitFor = checkoutFails
        ..stdoutFor = mismatchedSha;
      const repo = GitRepo(uri: 'https://x/y/foo.git', rev: 'v1');
      final result = await repo.sync(tmp, runner: git.run);

      expect(result.success, isFalse);
      expect(result.message, contains('checkout v1 failed'));
    });
  });

  group('resolvePatchesAgainst', () {
    test('rebases relative paths onto the declaring manifest directory', () {
      const repo = GitRepo(
        uri: 'https://github.com/google/filament.git',
        rev: 'v1.74.0',
        patches: ['patches/filament/0007-a.patch'],
      );
      final resolved = repo.resolvePatchesAgainst('/ws/app/fluorite/emb.yaml');

      expect(resolved.patches, [
        p.normalize('/ws/app/fluorite/patches/filament/0007-a.patch'),
      ]);
    });

    test('normalizes traversal segments', () {
      const repo = GitRepo(
        uri: 'https://x/y/z.git',
        patches: ['../shared/0001-x.patch'],
      );
      final resolved = repo.resolvePatchesAgainst('/ws/app/pkg/emb.yaml');

      expect(resolved.patches, [p.normalize('/ws/app/shared/0001-x.patch')]);
      expect(resolved.patches.single, isNot(contains('..')));
    });

    test('leaves absolute patch paths untouched', () {
      final abs = p.absolute(p.join(p.separator, 'etc', '0001-abs.patch'));
      final repo = GitRepo(uri: 'https://x/y/z.git', patches: [abs]);

      expect(repo.resolvePatchesAgainst('/ws/other/emb.yaml').patches, [abs]);
    });

    test('is a no-op without patches or without a declaring file', () {
      const none = GitRepo(uri: 'https://x/y/z.git');
      expect(
        identical(none.resolvePatchesAgainst('/ws/emb.yaml'), none),
        isTrue,
      );

      const some = GitRepo(uri: 'https://x/y/z.git', patches: ['a.patch']);
      expect(identical(some.resolvePatchesAgainst(null), some), isTrue);
    });

    test('preserves every other field', () {
      const repo = GitRepo(
        uri: 'https://x/y/z.git',
        branch: 'main',
        rev: 'v1.74.0',
        destName: 'renamed',
        patches: ['a.patch'],
      );
      final resolved = repo.resolvePatchesAgainst('/ws/emb.yaml');

      expect(resolved.uri, repo.uri);
      expect(resolved.branch, 'main');
      expect(resolved.rev, 'v1.74.0');
      expect(resolved.destName, 'renamed');
      expect(resolved.folderName, 'renamed');
    });

    test('resolves each repo against its own manifest when pooled', () {
      // The case that motivates resolving at load time: `emb sync` merges
      // repos from several manifests into one list before syncing, so a
      // single shared base directory would be wrong for all but one of them.
      const a = GitRepo(uri: 'https://x/y/a.git', patches: ['p/0001-a.patch']);
      const b = GitRepo(uri: 'https://x/y/b.git', patches: ['p/0001-b.patch']);

      final pooled = [
        a.resolvePatchesAgainst('/ws/app/alpha/emb.yaml'),
        b.resolvePatchesAgainst('/ws/app/beta/emb.yaml'),
      ];

      expect(
        pooled[0].patches.single,
        p.normalize('/ws/app/alpha/p/0001-a.patch'),
      );
      expect(
        pooled[1].patches.single,
        p.normalize('/ws/app/beta/p/0001-b.patch'),
      );
    });

    test('resolved paths are what sync actually looks for on disk', () async {
      // Ties resolution to behavior: a patch that exists relative to its
      // manifest must be found, proving the two halves agree.
      final manifestDir = Directory.systemTemp.createTempSync('emb_resolve_');
      addTearDown(() => manifestDir.deleteSync(recursive: true));
      Directory(p.join(manifestDir.path, 'patches')).createSync();
      File(
        p.join(manifestDir.path, 'patches', '0001-real.patch'),
      ).writeAsStringSync('--- a\n+++ b\n');

      final repo = const GitRepo(
        uri: 'https://x/y/foo.git',
        rev: 'v1',
        patches: ['patches/0001-real.patch'],
      ).resolvePatchesAgainst(p.join(manifestDir.path, 'emb.yaml'));

      final git = _FakeGit();
      final work = Directory.systemTemp.createTempSync('emb_resolve_work_');
      addTearDown(() => work.deleteSync(recursive: true));
      final result = await repo.sync(work, runner: git.run);

      expect(result.success, isTrue);
      expect(git.calls.where((c) => c.first == 'apply'), hasLength(2));
    });
  });

  group('patches', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('emb_patch_'));
    tearDown(() => tmp.deleteSync(recursive: true));

    /// Writes a patch file into [tmp] and returns its absolute path. The
    /// contents never matter: the fake git decides success or failure.
    String patchFile(String name) {
      final f = File(p.join(tmp.path, name))
        ..writeAsStringSync('--- a\n+++ b\n');
      return f.path;
    }

    test('parses patches from a manifest map, defaulting to empty', () {
      expect(SourceRepo.fromMap({'uri': 'https://x/y/z.git'}).patches, isEmpty);

      final s = SourceRepo.fromMap({
        'uri': 'https://github.com/google/filament.git',
        'rev': 'v1.74.0',
        'patches': [
          'patches/filament/0007-a.patch',
          'patches/filament/0008-b.patch',
        ],
      });
      expect(s.patches, [
        'patches/filament/0007-a.patch',
        'patches/filament/0008-b.patch',
      ]);
      expect(GitRepo.fromSource(s).patches, s.patches);
    });

    test('applies nothing when no patches are declared', () async {
      final git = _FakeGit();
      const repo = GitRepo(uri: 'https://x/y/foo.git', rev: 'v1');
      final result = await repo.sync(tmp, runner: git.run);

      expect(result.success, isTrue);
      expect(git.calls.where((c) => c.first == 'apply'), isEmpty);
    });

    test('checks then applies each patch, in declared order', () async {
      final git = _FakeGit();
      final first = patchFile('0001-first.patch');
      final second = patchFile('0002-second.patch');
      final repo = GitRepo(
        uri: 'https://x/y/foo.git',
        rev: 'v1',
        patches: [first, second],
      );
      final result = await repo.sync(tmp, runner: git.run);

      expect(result.success, isTrue);
      expect(git.calls.where((c) => c.first == 'apply').toList(), [
        ['apply', '--check', '--verbose', first],
        ['apply', first],
        ['apply', '--check', '--verbose', second],
        ['apply', second],
      ]);
    });

    test('applies patches after checkout', () async {
      final git = _FakeGit();
      final patch = patchFile('0001-only.patch');
      final repo = GitRepo(
        uri: 'https://x/y/foo.git',
        rev: 'v1',
        patches: [patch],
      );
      await repo.sync(tmp, runner: git.run);

      final checkoutAt = git.calls.indexWhere((c) => c.first == 'checkout');
      final applyAt = git.calls.indexWhere((c) => c.first == 'apply');
      expect(checkoutAt, isNonNegative);
      expect(applyAt, greaterThan(checkoutAt));
    });

    test('rejects a missing patch file before touching the worktree', () async {
      final git = _FakeGit();
      final repo = GitRepo(
        uri: 'https://x/y/foo.git',
        rev: 'v1',
        patches: [p.join(tmp.path, 'nope.patch')],
      );
      final result = await repo.sync(tmp, runner: git.run);

      expect(result.success, isFalse);
      expect(result.message, contains('do not exist'));
      expect(result.message, contains('nope.patch'));
      // Never ran git apply, and never reset the tree.
      expect(git.calls.where((c) => c.first == 'apply'), isEmpty);
    });

    test(
      'a patch that does not apply fails gracefully and explains why',
      () async {
        final git = _FakeGit()
          ..exitFor = (args) =>
              args.first == 'apply' && args.contains('--check') ? 1 : 0;
        final patch = patchFile('0007-vulkan.patch');
        final repo = GitRepo(
          uri: 'https://x/y/foo.git',
          rev: 'v1.74.0',
          patches: [patch],
        );
        final result = await repo.sync(tmp, runner: git.run);

        expect(result.success, isFalse);
        // Names the patch, its position, and the rev it was applied onto, so
        // version skew is diagnosable from the log alone.
        expect(result.message, contains('patch 1/1 failed'));
        expect(result.message, contains('0007-vulkan.patch'));
        expect(result.message, contains('v1.74.0'));
        expect(result.message, contains('tree was reset'));
        // Never ran the real apply after --check refused it.
        expect(git.calls, isNot(contains(equals(['apply', patch]))));
      },
    );

    test(
      'restores the worktree when a later patch in a series fails',
      () async {
        final good = patchFile('0001-good.patch');
        final bad = patchFile('0002-bad.patch');
        final git = _FakeGit()
          ..exitFor = (args) =>
              args.first == 'apply' && args.contains(bad) ? 1 : 0;
        final repo = GitRepo(
          uri: 'https://x/y/foo.git',
          rev: 'v1',
          patches: [good, bad],
        );
        final result = await repo.sync(tmp, runner: git.run);

        expect(result.success, isFalse);
        expect(result.message, contains('patch 2/2 failed'));
        // Reports that one patch preceded it — distinguishes a stale patch
        // from a series whose earlier entry moved the same lines.
        expect(result.message, contains('after 1 patch(es) before it'));
        // The already-applied first patch is rolled back.
        expect(git.calls, contains(equals(['reset', '--hard'])));
        expect(git.calls, contains(equals(['clean', '-fd'])));
      },
    );

    test('surfaces git output in the failure message', () async {
      const detail = 'error: patch failed: Foo.cpp:26';
      final git = _FakeGit()
        ..exitFor = ((args) => args.first == 'apply' ? 1 : 0)
        ..stdoutFor = ((args) => args.first == 'apply' ? detail : '');
      final repo = GitRepo(
        uri: 'https://x/y/foo.git',
        rev: 'v1',
        patches: [patchFile('0001-x.patch')],
      );
      final result = await repo.sync(tmp, runner: git.run);

      expect(result.success, isFalse);
      expect(result.message, contains(detail));
    });
  });
}
