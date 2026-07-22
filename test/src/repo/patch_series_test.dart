import 'dart:io';

import 'package:emb_cli/src/repo/patch_series.dart';
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
    return ProcessResult(0, exitFor?.call(args) ?? 0, '', '');
  }
}

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('emb_series_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  String write(String name, String body) {
    final f = File(p.join(tmp.path, name))..writeAsStringSync(body);
    return f.path;
  }

  group('resolvePatchPaths', () {
    test('rebases relative paths and leaves absolute ones alone', () {
      final abs = p.join(p.separator, 'etc', 'b.patch');
      expect(resolvePatchPaths(['a.patch', abs], '/ws/manifest'), [
        p.normalize('/ws/manifest/a.patch'),
        abs,
      ]);
    });

    test('normalizes traversal segments', () {
      expect(resolvePatchPaths(['../up.patch'], '/ws/a/b'), [
        p.normalize('/ws/a/up.patch'),
      ]);
    });
  });

  group('patchSeriesDigest', () {
    test('is stable for the same contents', () {
      final a = write('0001.patch', 'diff one');
      expect(patchSeriesDigest([a]), patchSeriesDigest([a]));
    });

    test('changes when a patch is edited in place', () {
      // The whole point of hashing contents rather than paths: `url`/`rev`
      // do not move when a patch is edited, so nothing else would notice.
      final a = write('0001.patch', 'diff one');
      final before = patchSeriesDigest([a]);
      File(a).writeAsStringSync('diff one, revised');
      expect(patchSeriesDigest([a]), isNot(before));
    });

    test('changes when the series is reordered', () {
      final a = write('0001.patch', 'aaa');
      final b = write('0002.patch', 'bbb');
      expect(patchSeriesDigest([a, b]), isNot(patchSeriesDigest([b, a])));
    });

    test('distinguishes same content under different names', () {
      final a = write('0001-alpha.patch', 'same');
      final b = write('0002-beta.patch', 'same');
      expect(patchSeriesDigest([a]), isNot(patchSeriesDigest([b])));
    });

    test('does not throw on a missing patch', () {
      expect(
        patchSeriesDigest([p.join(tmp.path, 'absent.patch')]),
        isA<String>(),
      );
    });

    test('is empty-series stable', () {
      expect(patchSeriesDigest(const []), patchSeriesDigest(const []));
    });
  });

  group('applyPatchSeries', () {
    test('is a no-op for an empty series', () async {
      final git = _FakeGit();
      await applyPatchSeries(
        runner: git.run,
        workDir: tmp.path,
        patches: const [],
        onto: 'v1',
      );
      expect(git.calls, isEmpty);
    });

    test('checks then applies each patch in order', () async {
      final git = _FakeGit();
      final a = write('0001.patch', 'a');
      final b = write('0002.patch', 'b');
      await applyPatchSeries(
        runner: git.run,
        workDir: tmp.path,
        patches: [a, b],
        onto: 'v1',
      );
      expect(git.calls, [
        ['apply', '--check', '--verbose', a],
        ['apply', a],
        ['apply', '--check', '--verbose', b],
        ['apply', b],
      ]);
    });

    test('rejects a missing patch before touching the tree', () async {
      final git = _FakeGit();
      await expectLater(
        applyPatchSeries(
          runner: git.run,
          workDir: tmp.path,
          patches: [p.join(tmp.path, 'nope.patch')],
          onto: 'v1',
        ),
        throwsA(
          isA<PatchSeriesException>().having(
            (e) => e.message,
            'message',
            contains('do not exist'),
          ),
        ),
      );
      expect(git.calls, isEmpty);
    });

    test('invokes restore and explains the failure', () async {
      final git = _FakeGit()..exitFor = ((args) => 1);
      final a = write('0007-vulkan.patch', 'a');
      var restored = false;

      await expectLater(
        applyPatchSeries(
          runner: git.run,
          workDir: tmp.path,
          patches: [a],
          onto: 'filament 1.74.0',
          restore: () async => restored = true,
        ),
        throwsA(
          isA<PatchSeriesException>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('patch 1/1 failed'),
              contains('0007-vulkan.patch'),
              // Names what it was applied onto: version skew is the usual
              // cause and is otherwise invisible from the log.
              contains('filament 1.74.0'),
              contains('tree was reset'),
            ),
          ),
        ),
      );
      expect(restored, isTrue);
      // --check refused it, so the real apply never ran.
      expect(git.calls, isNot(contains(equals(['apply', a]))));
    });

    test('reports which patches preceded a mid-series failure', () async {
      final b = write('0002-bad.patch', 'b');
      final git = _FakeGit()..exitFor = ((args) => args.contains(b) ? 1 : 0);
      final a = write('0001-good.patch', 'a');

      await expectLater(
        applyPatchSeries(
          runner: git.run,
          workDir: tmp.path,
          patches: [a, b],
          onto: 'v1',
        ),
        throwsA(
          isA<PatchSeriesException>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('patch 2/2 failed'),
              contains('after 1 patch(es) before it'),
            ),
          ),
        ),
      );
    });

    test('works without a restore callback', () async {
      final git = _FakeGit()..exitFor = ((args) => 1);
      final a = write('0001.patch', 'a');
      await expectLater(
        applyPatchSeries(
          runner: git.run,
          workDir: tmp.path,
          patches: [a],
          onto: 'v1',
        ),
        throwsA(isA<PatchSeriesException>()),
      );
    });
  });
}
