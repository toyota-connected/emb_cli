import 'dart:convert';
import 'dart:io';

import 'package:emb_cli/src/cross/package_stager.dart';
import 'package:emb_cli/src/cross/process_runner.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

class _TestStager extends PackageStager {
  _TestStager(super.run);

  @override
  Never fail(String message) => throw StateError(message);
}

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('emb_stage_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test(
    'stages many extra files with bounded chmod calls and correct modes',
    () async {
      final chmodCalls = <List<String>>[];
      Future<RunResult> fakeRun(
        String executable,
        List<String> arguments, {
        String? workingDirectory,
        Map<String, String>? environment,
        bool includeParentEnvironment = true,
        bool runInShell = false,
        ProcessOutputMode output = ProcessOutputMode.capture,
        String? label,
      }) async {
        if (executable == 'chmod') chmodCalls.add(List.of(arguments));
        return const RunResult(0, '', '');
      }

      final binary = File(p.join(tmp.path, 'app'))..writeAsStringSync('app');
      final extras = <String, String>{};
      final modes = <String, String>{};
      final contents = <String, String>{};
      final deepDir = 'x'.padRight(160, 'x');
      for (var i = 0; i < 960; i++) {
        final source = File(p.join(tmp.path, 'source', 'file $i.txt'))
          ..createSync(recursive: true)
          ..writeAsStringSync('$i');
        extras[source.path] = '/usr/share/emb/$deepDir/file $i.txt';
        modes[source.path] = i.isEven ? '0644' : '0755';
        contents[source.path] = '$i';
      }
      final unmoded = File(p.join(tmp.path, 'source', 'unmoded.txt'))
        ..writeAsStringSync('keep');
      extras[unmoded.path] = '/usr/share/emb/unmoded.txt';
      contents[unmoded.path] = 'keep';

      final root = await _TestStager(fakeRun).stagePayload(
        binary: binary,
        installPath: '/usr/bin/app',
        packageName: 'example',
        outDir: Directory(p.join(tmp.path, 'out')),
        extraFiles: extras,
        fileModes: modes,
      );

      expect(chmodCalls.first, [
        '--',
        '0755',
        p.join(root.path, 'usr/bin/app'),
      ]);
      final extraCalls = chmodCalls.skip(1).toList();
      expect(extraCalls.length, lessThan(12));

      final expected = <String, Set<String>>{'0644': {}, '0755': {}};
      for (final entry in extras.entries) {
        final staged = p.join(root.path, entry.value.substring(1));
        expect(File(staged).readAsStringSync(), contents[entry.key]);
        final mode = modes[entry.key];
        if (mode != null) expected[mode]!.add(staged);
      }

      final actual = <String, Set<String>>{'0644': {}, '0755': {}};
      var pathCount = 0;
      for (final args in extraCalls) {
        expect(args.length, greaterThan(2));
        expect(
          utf8.encode(args.join('\u0000')).length + 1,
          lessThanOrEqualTo(100 * 1024),
        );
        expect(args.first, '--');
        final mode = args[1];
        expect(actual, contains(mode));
        actual[mode]!.addAll(args.skip(2));
        pathCount += args.length - 2;
      }
      expect(pathCount, 960);
      expect(actual, expected);
    },
  );

  test('keeps a 2000-file single-mode package to a few chmod calls', () async {
    final chmodCalls = <List<String>>[];
    Future<RunResult> fakeRun(
      String executable,
      List<String> arguments, {
      String? workingDirectory,
      Map<String, String>? environment,
      bool includeParentEnvironment = true,
      bool runInShell = false,
      ProcessOutputMode output = ProcessOutputMode.capture,
      String? label,
    }) async {
      if (executable == 'chmod') chmodCalls.add(List.of(arguments));
      return const RunResult(0, '', '');
    }

    final binary = File(p.join(tmp.path, 'app'))..writeAsStringSync('app');
    final extras = <String, String>{};
    final modes = <String, String>{};
    for (var i = 0; i < 2000; i++) {
      final source = File(p.join(tmp.path, 'source', 'f$i'))
        ..createSync(recursive: true)
        ..writeAsStringSync('$i');
      extras[source.path] = '/assets/f$i';
      modes[source.path] = '0644';
    }

    final root = await _TestStager(fakeRun).stagePayload(
      binary: binary,
      installPath: '/usr/bin/app',
      packageName: 'example',
      outDir: Directory(p.join(tmp.path, 'out')),
      extraFiles: extras,
      fileModes: modes,
    );
    final extraCalls = chmodCalls.skip(1).toList();
    expect(extraCalls.length, lessThanOrEqualTo(3));
    for (final args in extraCalls) {
      expect(args.take(2).toList(), ['--', '0644']);
    }
    expect(extraCalls.expand((args) => args.skip(2)).toSet(), {
      for (final dest in extras.values) p.join(root.path, dest.substring(1)),
    });
  });

  test('preserves chmod order when sources share a target path', () async {
    final calls = <List<String>>[];
    Future<RunResult> fakeRun(
      String executable,
      List<String> arguments, {
      String? workingDirectory,
      Map<String, String>? environment,
      bool includeParentEnvironment = true,
      bool runInShell = false,
      ProcessOutputMode output = ProcessOutputMode.capture,
      String? label,
    }) async {
      if (executable == 'chmod') calls.add(List.of(arguments));
      return const RunResult(0, '', '');
    }

    final binary = File(p.join(tmp.path, 'app'))..writeAsStringSync('app');
    final first = File(p.join(tmp.path, 'first'))..writeAsStringSync('a');
    final second = File(p.join(tmp.path, 'second'))..writeAsStringSync('b');
    final third = File(p.join(tmp.path, 'third'))..writeAsStringSync('c');
    final root = await _TestStager(fakeRun).stagePayload(
      binary: binary,
      installPath: '/usr/bin/app',
      packageName: 'example',
      outDir: Directory(p.join(tmp.path, 'out')),
      extraFiles: {
        first.path: '/share/repeated',
        second.path: '/share/repeated',
        third.path: '/share/repeated',
      },
      fileModes: {first.path: '0600', second.path: '0644'},
    );
    final target = p.join(root.path, 'share/repeated');
    expect(File(target).readAsStringSync(), 'c');
    expect(calls, [
      ['--', '0755', p.join(root.path, 'usr/bin/app')],
      ['--', '0600', target],
      ['--', '0644', target],
    ]);
  });

  test('an option-shaped mode is refused before chmod runs', () async {
    // `--` keeps chmod from reading the mode as an option; validating it keeps
    // the invalid mode from reaching chmod at all, which names the manifest
    // field instead of reporting a chmod exit code.
    final calls = <List<String>>[];
    Future<RunResult> fakeRun(
      String executable,
      List<String> arguments, {
      String? workingDirectory,
      Map<String, String>? environment,
      bool includeParentEnvironment = true,
      bool runInShell = false,
      ProcessOutputMode output = ProcessOutputMode.capture,
      String? label,
    }) async {
      if (executable == 'chmod') calls.add(List.of(arguments));
      return const RunResult(0, '', '');
    }

    final binary = File(p.join(tmp.path, 'app'))..writeAsStringSync('app');
    final extra = File(p.join(tmp.path, 'extra'))..writeAsStringSync('extra');
    for (final mode in ['--reference=unexpected', '0999', 'u+x', '']) {
      await expectLater(
        _TestStager(fakeRun).stagePayload(
          binary: binary,
          installPath: '/usr/bin/app',
          packageName: 'example',
          outDir: Directory(p.join(tmp.path, 'out')),
          extraFiles: {extra.path: '/share/extra'},
          fileModes: {extra.path: mode},
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.toString(),
            'message',
            contains('file mode must be 3-4 octal digits'),
          ),
        ),
        reason: 'mode "$mode" must be refused',
      );
    }
    expect(calls, isEmpty, reason: 'nothing may be chmodded on a bad mode');
  });

  test('a batched chmod failure is reported', () async {
    // The exit-code check still has to hold for a mode that passes validation.
    final calls = <List<String>>[];
    Future<RunResult> fakeRun(
      String executable,
      List<String> arguments, {
      String? workingDirectory,
      Map<String, String>? environment,
      bool includeParentEnvironment = true,
      bool runInShell = false,
      ProcessOutputMode output = ProcessOutputMode.capture,
      String? label,
    }) async {
      if (executable == 'chmod') calls.add(List.of(arguments));
      if (arguments.contains('0640')) {
        return const RunResult(1, '', 'Operation not permitted');
      }
      return const RunResult(0, '', '');
    }

    final binary = File(p.join(tmp.path, 'app'))..writeAsStringSync('app');
    final extra = File(p.join(tmp.path, 'extra'))..writeAsStringSync('extra');
    await expectLater(
      _TestStager(fakeRun).stagePayload(
        binary: binary,
        installPath: '/usr/bin/app',
        packageName: 'example',
        outDir: Directory(p.join(tmp.path, 'out')),
        extraFiles: {extra.path: '/share/extra'},
        fileModes: {extra.path: '0640'},
      ),
      throwsA(
        isA<StateError>().having(
          (e) => e.toString(),
          'message',
          contains('chmod failed (exit 1): Operation not permitted'),
        ),
      ),
    );
    expect(calls.last.take(2).toList(), ['--', '0640']);
  });

  test('a destination that escapes the staging root is refused', () async {
    // isAbsolute does not stop `/../..`: the file used to land outside the root,
    // so it survived the clean, and `/../<pkg>.stage/DEBIAN/postinst`
    // normalized back inside the package past the script allowlist.
    Future<RunResult> fakeRun(
      String executable,
      List<String> arguments, {
      String? workingDirectory,
      Map<String, String>? environment,
      bool includeParentEnvironment = true,
      bool runInShell = false,
      ProcessOutputMode output = ProcessOutputMode.capture,
      String? label,
    }) async => const RunResult(0, '', '');

    final binary = File(p.join(tmp.path, 'app'))..writeAsStringSync('app');
    final extra = File(p.join(tmp.path, 'extra'))..writeAsStringSync('extra');
    for (final dest in [
      '/../../ESCAPED/pwned.txt',
      '/../example.stage/DEBIAN/postinst',
    ]) {
      await expectLater(
        _TestStager(fakeRun).stagePayload(
          binary: binary,
          installPath: '/usr/bin/app',
          packageName: 'example',
          outDir: Directory(p.join(tmp.path, 'out')),
          extraFiles: {extra.path: dest},
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.toString(),
            'message',
            anyOf(
              contains('escapes the staging root'),
              contains('must not contain ".."'),
            ),
          ),
        ),
        reason: 'dest "$dest" must be refused',
      );
    }
    expect(
      File(p.join(tmp.path, 'ESCAPED', 'pwned.txt')).existsSync(),
      isFalse,
    );
  });

  test('a package name that is a path is refused', () async {
    // packageName names the staging dir, which is deleted recursively — and
    // p.join drops its base when the next part is absolute.
    Future<RunResult> fakeRun(
      String executable,
      List<String> arguments, {
      String? workingDirectory,
      Map<String, String>? environment,
      bool includeParentEnvironment = true,
      bool runInShell = false,
      ProcessOutputMode output = ProcessOutputMode.capture,
      String? label,
    }) async => const RunResult(0, '', '');

    final victim = Directory(p.join(tmp.path, 'important'))..createSync();
    File(p.join(victim.path, 'keep.txt')).writeAsStringSync('precious');
    final binary = File(p.join(tmp.path, 'app'))..writeAsStringSync('app');
    for (final name in ['../../important', '/tmp/absolute', 'a/b', '..']) {
      await expectLater(
        _TestStager(fakeRun).stagePayload(
          binary: binary,
          installPath: '/usr/bin/app',
          packageName: name,
          outDir: Directory(p.join(tmp.path, 'out', 'dist')),
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.toString(),
            'message',
            contains('package name must match'),
          ),
        ),
        reason: 'name "$name" must be refused',
      );
    }
    expect(File(p.join(victim.path, 'keep.txt')).existsSync(), isTrue);
  });
}
