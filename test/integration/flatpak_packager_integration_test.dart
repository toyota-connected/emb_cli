@Tags(['flatpak'])
library;

import 'dart:io';

import 'package:emb_cli/src/cross/flatpak_packager.dart';
import 'package:emb_cli/src/cross/process_runner.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Drives [FlatpakPackager] against a real `flatpak-builder`.
///
/// The unit tests in `test/src/cross/flatpak_packager_test.dart` assert the
/// generated manifest and launcher as text, with every process faked. What they
/// cannot tell you is whether flatpak-builder *accepts* either — a manifest key
/// it rejects, or a launcher the runtime's shell will not run, looks identical
/// to a passing test. This fills that gap and nothing else, so it stays small.
///
/// Tagged `flatpak`, so it runs only where the toolchain is present: `dart test
/// -t flatpak`. The default `dart test` run excludes it (see dart_test.yaml).
void main() {
  late Directory tmp;
  String? runtimeBranch;

  setUpAll(() async {
    // Both halves are needed: flatpak-builder builds against the Sdk and the
    // result runs against the Platform, and emb declares one branch for both.
    final list = await Process.run('flatpak', [
      'list',
      '--runtime',
      '--columns=application,branch',
    ]);
    if (list.exitCode != 0) return;
    final platforms = <String>{};
    final sdks = <String>{};
    for (final line in (list.stdout as String).split('\n')) {
      final parts = line.trim().split(RegExp(r'\s+'));
      if (parts.length < 2) continue;
      if (parts[0] == 'org.freedesktop.Platform') platforms.add(parts[1]);
      if (parts[0] == 'org.freedesktop.Sdk') sdks.add(parts[1]);
    }
    final both = platforms.intersection(sdks).toList()..sort();
    runtimeBranch = both.isEmpty ? null : both.last;
  });

  setUp(() => tmp = Directory.systemTemp.createTempSync('emb_fp_it_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  /// A runnable bundle shaped like the one `--app` assembles: an embedder plus
  /// the data the engine would sit in. The embedder is a shell script because
  /// nothing here runs it; flatpak-builder only has to copy it.
  Directory bundle() {
    final dir = Directory(p.join(tmp.path, 'runnable'))
      ..createSync(recursive: true);
    File(p.join(dir.path, 'homescreen'))
      ..writeAsStringSync(
        '#!/bin/sh\necho '
        r'"$@"'
        '\n',
      )
      ..setLastModifiedSync(DateTime.now());
    Process.runSync('chmod', ['0755', p.join(dir.path, 'homescreen')]);
    Directory(
      p.join(dir.path, 'data', 'flutter_assets'),
    ).createSync(recursive: true);
    File(
      p.join(dir.path, 'data', 'flutter_assets', 'AssetManifest.json'),
    ).writeAsStringSync('{}');
    return dir;
  }

  /// Runs the real toolchain, snapshotting the generated launcher before
  /// `build()` deletes its context. The launcher is written beside the
  /// manifest, which is flatpak-builder's last argument.
  ({ProcessRunner run, List<String> captured}) capturingRunner() {
    final captured = <String>[];
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
      if (exe == 'flatpak-builder' && workingDirectory != null) {
        final launcher = File(p.join(workingDirectory, 'launcher.sh'));
        if (launcher.existsSync()) captured.add(launcher.readAsStringSync());
      }
      final r = await Process.run(
        exe,
        args,
        workingDirectory: workingDirectory,
        environment: environment,
      );
      return RunResult(r.exitCode, '${r.stdout}', '${r.stderr}');
    }

    return (run: run, captured: captured);
  }

  test('flatpak-builder accepts the generated manifest and launcher', () async {
    final branch = runtimeBranch;
    if (branch == null) {
      markTestSkipped(
        'needs org.freedesktop.Platform and .Sdk at the same branch: '
        'flatpak install flathub org.freedesktop.Platform//23.08 '
        'org.freedesktop.Sdk//23.08',
      );
      return;
    }
    final runner = capturingRunner();
    final out = await FlatpakPackager(runProcess: runner.run).build(
      bundleDir: bundle(),
      outDir: Directory(p.join(tmp.path, 'dist')),
      meta: FlatpakMetadata(
        appId: 'com.example.EmbCliIntegration',
        command: 'homescreen',
        runtimeVersion: branch,
        // The point of the exercise: a bundle flag that is not `-b`, declared
        // once as cross.run.command. A launcher flatpak-builder rejects, or a
        // quoting bug in it, is invisible to the faked unit tests.
        runCommand: const [r'./${embedder}', '--asset-dir', r'${deploy_dir}'],
      ),
    );

    expect(out.existsSync(), isTrue, reason: 'no bundle produced');
    expect(out.lengthSync(), greaterThan(0));
    expect(runner.captured, hasLength(1), reason: 'launcher not captured');
    final exec = runner.captured.single.trim().split('\n').last;
    expect(
      exec,
      'exec /app/com.example.EmbCliIntegration/homescreen --asset-dir '
      r'/app/com.example.EmbCliIntegration "$@"',
    );
  }, timeout: const Timeout(Duration(minutes: 10)));
}
