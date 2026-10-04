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

      expect(chmodCalls.first, ['0755', p.join(root.path, 'usr/bin/app')]);
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
        expect(args.length, greaterThan(1));
        expect(
          utf8.encode(args.join('\u0000')).length + 1,
          lessThanOrEqualTo(100 * 1024),
        );
        final mode = args.first;
        expect(actual, contains(mode));
        actual[mode]!.addAll(args.skip(1));
        pathCount += args.length - 1;
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
    expect(extraCalls.map((args) => args.first).toSet(), {'0644'});
    expect(extraCalls.expand((args) => args.skip(1)).toSet(), {
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
      ['0755', p.join(root.path, 'usr/bin/app')],
      ['0600', target],
      ['0644', target],
    ]);
  });
}
