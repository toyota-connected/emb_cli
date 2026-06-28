import 'dart:io';

import 'package:emb_cli/src/cross/flatpak_packager.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('emb_flatpak_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  // A fake ProcessRunner standing in for command/cp/flatpak-builder/flatpak,
  // capturing the generated manifest before the context dir is removed.
  String? capturedManifest;
  String? capturedLauncher;
  List<String>? builderArgv;
  List<String>? bundleArgv;
  Future<ProcessResult> fakeRun(
    String exe,
    List<String> args, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool includeParentEnvironment = true,
    bool runInShell = false,
  }) async {
    if (exe == 'command') return ProcessResult(0, 0, '/usr/bin/$exe\n', '');
    if (exe == 'cp') {
      // Emulate `cp -a . <dst>` for the bundle stage.
      final dst = args.last;
      Directory(dst).createSync(recursive: true);
      return ProcessResult(0, 0, '', '');
    }
    if (exe == 'flatpak-builder') {
      builderArgv = args;
      // The manifest is the last arg; the launcher sits beside it.
      final ctx = workingDirectory!;
      capturedManifest = File(args.last).readAsStringSync();
      capturedLauncher = File(p.join(ctx, 'launcher.sh')).readAsStringSync();
      return ProcessResult(0, 0, '', '');
    }
    if (exe == 'flatpak' && args.first == 'build-bundle') {
      bundleArgv = args;
      File(args[2]).writeAsStringSync('flatpak'); // out path
      return ProcessResult(0, 0, '', '');
    }
    return ProcessResult(0, 0, '', '');
  }

  Directory fakeBundle() {
    final dir = Directory(p.join(tmp.path, 'runnable'))..createSync();
    File(p.join(dir.path, 'homescreen')).writeAsStringSync('elf');
    Directory(p.join(dir.path, 'data')).createSync();
    Directory(p.join(dir.path, 'lib')).createSync();
    return dir;
  }

  test('builds a .flatpak, manifest + launcher target the bundle', () async {
    final packager = FlatpakPackager(runProcess: fakeRun);
    final out = await packager.build(
      bundleDir: fakeBundle(),
      meta: const FlatpakMetadata(
        appId: 'com.example.Homescreen',
        command: 'homescreen',
        arch: 'aarch64',
      ),
      outDir: Directory(p.join(tmp.path, 'dist')),
    );

    expect(out.path, endsWith('com.example.Homescreen_stable_aarch64.flatpak'));
    // Manifest wires the runtime, command, and a simple `dir`-sourced module.
    expect(capturedManifest, contains('app-id: com.example.Homescreen'));
    // Branch is pinned so the export ref matches build-bundle's branch.
    expect(capturedManifest, contains('branch: stable'));
    expect(capturedManifest, contains('command: homescreen'));
    expect(capturedManifest, contains('buildsystem: simple'));
    expect(capturedManifest, contains('cp -r bundle/. /app/com.example.'));
    expect(capturedManifest, contains('--socket=wayland'));
    // Launcher execs the embedder against its in-prefix bundle dir.
    expect(
      capturedLauncher,
      contains('exec /app/com.example.Homescreen/homescreen -b'),
    );
    // build-bundle is invoked for the right app id + branch + arch.
    expect(builderArgv, contains('--arch=aarch64'));
    expect(bundleArgv, containsAll(['com.example.Homescreen', 'stable']));
  });

  test('maps extra files into the /app prefix', () async {
    final cfg = File(p.join(tmp.path, 'app.toml'))..writeAsStringSync('x');
    final packager = FlatpakPackager(runProcess: fakeRun);
    await packager.build(
      bundleDir: fakeBundle(),
      meta: const FlatpakMetadata(
        appId: 'com.example.App',
        command: 'homescreen',
      ),
      outDir: Directory(p.join(tmp.path, 'dist')),
      extraFiles: {cfg.path: 'etc/app.toml'},
    );
    // Leading-slash-free dest lands under /app; install command is emitted.
    expect(
      capturedManifest,
      contains('install -Dm644 extra/0 /app/etc/app.toml'),
    );
  });

  test('rejects a non-reverse-DNS app id', () async {
    final packager = FlatpakPackager(runProcess: fakeRun);
    expect(
      () => packager.build(
        bundleDir: fakeBundle(),
        meta: const FlatpakMetadata(appId: 'homescreen', command: 'homescreen'),
        outDir: Directory(p.join(tmp.path, 'dist')),
      ),
      throwsA(isA<FlatpakPackageException>()),
    );
  });

  test('errors when the embedder is missing from the bundle', () async {
    final empty = Directory(p.join(tmp.path, 'empty'))..createSync();
    final packager = FlatpakPackager(runProcess: fakeRun);
    expect(
      () => packager.build(
        bundleDir: empty,
        meta: const FlatpakMetadata(
          appId: 'com.example.App',
          command: 'homescreen',
        ),
        outDir: Directory(p.join(tmp.path, 'dist')),
      ),
      throwsA(isA<FlatpakPackageException>()),
    );
  });
}
