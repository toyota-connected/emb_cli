@Tags(['integration'])
library;

import 'dart:io';

import 'package:emb_cli/src/repo/patch_series.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Exercises applyPatchSeries against the real `git` binary.
///
/// The fake-runner tests cover argument order and error handling, but they
/// cannot catch git deciding, on its own, not to apply anything: `git apply`
/// resolves patch paths against the enclosing repository when one exists, so a
/// tree nested inside an unrelated repo gets `Skipped patch ...` for every file
/// and an exit status of 0. That is what these cover.
Future<ProcessResult> realGit(
  List<String> args, {
  required String workingDirectory,
}) => Process.run('git', args, workingDirectory: workingDirectory);

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('emb_git_apply_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  /// A source tree containing one file, plus a patch that rewrites it.
  ({String dir, String patch}) fixture(String root) {
    final src = Directory(p.join(root, 'src'))..createSync(recursive: true);
    File(p.join(src.path, 'hello.txt')).writeAsStringSync('before\n');
    final patch = File(p.join(root, '0001-rewrite.patch'))
      ..writeAsStringSync(
        'diff --git a/hello.txt b/hello.txt\n'
        '--- a/hello.txt\n'
        '+++ b/hello.txt\n'
        '@@ -1 +1 @@\n'
        '-before\n'
        '+after\n',
      );
    return (dir: src.path, patch: patch.path);
  }

  Future<void> apply(({String dir, String patch}) f) => applyPatchSeries(
    runner: realGit,
    workDir: f.dir,
    patches: [f.patch],
    onto: 'fixture',
  );

  test('applies to a plain directory', () async {
    final f = fixture(tmp.path);
    await apply(f);
    expect(File(p.join(f.dir, 'hello.txt')).readAsStringSync(), 'after\n');
  });

  test('applies to a tree nested inside an unrelated git repository', () async {
    // The regression: an unpacked augment tarball lives under a workspace
    // directory that sits inside the project's own repo. git then resolves the
    // patch paths against that repo's root, skips every file, and exits 0 --
    // so the series reports success having changed nothing.
    final outer = Directory(p.join(tmp.path, 'outer'))..createSync();
    final init = await Process.run('git', [
      'init',
      '-q',
    ], workingDirectory: outer.path);
    expect(init.exitCode, 0, reason: 'git init failed: ${init.stderr}');

    final f = fixture(p.join(outer.path, 'workspace', 'unpacked'));
    await apply(f);

    expect(
      File(p.join(f.dir, 'hello.txt')).readAsStringSync(),
      'after\n',
      reason: 'patch was reported applied but the file is unchanged',
    );
  });

  test(
    'a genuinely non-applying patch still fails inside a repository',
    () async {
      // The mirror of the above: forcing no-repository mode must not make git
      // lenient. A patch whose context does not match has to be rejected.
      final outer = Directory(p.join(tmp.path, 'outer2'))..createSync();
      await Process.run('git', ['init', '-q'], workingDirectory: outer.path);

      final f = fixture(p.join(outer.path, 'ws', 'unpacked'));
      File(p.join(f.dir, 'hello.txt')).writeAsStringSync('something else\n');

      await expectLater(
        apply(f),
        throwsA(
          isA<PatchSeriesException>().having(
            (e) => e.message,
            'message',
            contains('0001-rewrite.patch'),
          ),
        ),
      );
    },
  );

  test('applies to a git checkout, where workDir is itself the repo', () async {
    // GitRepo's case: forcing no-repository mode must not break the ordinary
    // path where the tree being patched is a repository in its own right.
    final f = fixture(p.join(tmp.path, 'checkout'));
    final init = await Process.run('git', [
      'init',
      '-q',
    ], workingDirectory: f.dir);
    expect(init.exitCode, 0);

    await apply(f);
    expect(File(p.join(f.dir, 'hello.txt')).readAsStringSync(), 'after\n');
  });
}
