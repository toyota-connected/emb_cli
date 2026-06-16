import 'dart:io';

import 'package:emb_cli/src/flutter/flutter_sdk.dart';
import 'package:emb_cli/src/workspace/workspace.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

class _FakeGit {
  final List<List<String>> calls = [];
  Future<ProcessResult> run(
    List<String> args, {
    required String workingDirectory,
  }) async {
    calls.add(args);
    return ProcessResult(0, 0, '', '');
  }
}

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('emb_fl_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('clones flutter.git into <workspace>/flutter at the version', () async {
    final ws = Workspace(tmp);
    final sdk = FlutterSdk(ws);
    final git = _FakeGit();

    final result = await sdk.install('3.44.2', runner: git.run);

    expect(result.path, p.join(tmp.path, 'flutter'));
    // Clone with the version as branch/tag into the `flutter` dir.
    expect(
      git.calls.first,
      ['clone', FlutterSdk.repoUrl, 'flutter', '-b', '3.44.2'],
    );
    expect(git.calls, contains(equals(['checkout', '3.44.2'])));
  });

  test('reads the engine commit after checkout', () async {
    final ws = Workspace(tmp);
    // Simulate an already-cloned SDK (.git present → update path, not a fresh
    // clone) with engine.version committed.
    Directory(p.join(tmp.path, 'flutter', '.git')).createSync(recursive: true);
    final internal = Directory(p.join(tmp.path, 'flutter', 'bin', 'internal'))
      ..createSync(recursive: true);
    File(p.join(internal.path, 'engine.version'))
        .writeAsStringSync('deadbeefcafe\n');

    final result =
        await FlutterSdk(ws).install('3.44.2', runner: _FakeGit().run);
    expect(result.engineCommit, 'deadbeefcafe');
  });
}
