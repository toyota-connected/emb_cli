import 'dart:io';

import 'package:emb_cli/src/cross/flatpak_packager.dart';
import 'package:emb_cli/src/cross/process_runner.dart';
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
  Future<RunResult> fakeRun(
    String exe,
    List<String> args, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool includeParentEnvironment = true,
    bool runInShell = false,
    ProcessOutputMode output = ProcessOutputMode.capture,
    String? label,
  }) async {
    if (exe == 'command') return RunResult(0, '/usr/bin/$exe\n', '');
    if (exe == 'cp') {
      // Emulate `cp -a . <dst>` for the bundle stage.
      final dst = args.last;
      Directory(dst).createSync(recursive: true);
      return const RunResult(0, '', '');
    }
    if (exe == 'flatpak-builder') {
      builderArgv = args;
      // The manifest is the last arg; the launcher sits beside it.
      final ctx = workingDirectory!;
      capturedManifest = File(args.last).readAsStringSync();
      capturedLauncher = File(p.join(ctx, 'launcher.sh')).readAsStringSync();
      return const RunResult(0, '', '');
    }
    if (exe == 'flatpak' && args.first == 'build-bundle') {
      bundleArgv = args;
      File(args[2]).writeAsStringSync('flatpak'); // out path
      return const RunResult(0, '', '');
    }
    return const RunResult(0, '', '');
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

  test('applies an explicit per-file mode in the install command', () async {
    final helper = File(p.join(tmp.path, 'helper'))..writeAsStringSync('#!sh');
    final packager = FlatpakPackager(runProcess: fakeRun);
    await packager.build(
      bundleDir: fakeBundle(),
      meta: const FlatpakMetadata(
        appId: 'com.example.App',
        command: 'homescreen',
      ),
      outDir: Directory(p.join(tmp.path, 'dist')),
      extraFiles: {helper.path: 'bin/helper'},
      fileModes: {helper.path: '0755'},
    );
    expect(
      capturedManifest,
      contains('install -Dm0755 extra/0 /app/bin/helper'),
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

  test('launcher carries env assignments and embedder args', () async {
    final out = Directory(p.join(tmp.path, 'dist'));
    await FlatpakPackager(runProcess: fakeRun).build(
      bundleDir: fakeBundle(),
      outDir: out,
      meta: const FlatpakMetadata(
        appId: 'com.example.App',
        command: 'homescreen',
        env: {'IHS_LOG_LEVEL': 'info', 'XDG_DATA_HOME': r'$HOME/.local/share'},
        args: ['--backend=wayland-egl', '--app-id=com.example.App'],
      ),
    );
    final lines = capturedLauncher!.trim().split('\n');
    expect(lines.first, '#!/bin/sh');
    // A plain assignment, not `${NAME:-value}`: flatpak pre-sets the variables
    // this field exists to control, so a default would never fire.
    expect(lines, contains('export IHS_LOG_LEVEL="info"'));
    // The value is shell text: $HOME expands in the sandbox, not at build time.
    expect(lines, contains(r'export XDG_DATA_HOME="$HOME/.local/share"'));
    expect(
      lines.last,
      'exec /app/com.example.App/homescreen -b /app/com.example.App '
      r'--backend=wayland-egl --app-id=com.example.App "$@"',
    );
  });

  test('launcher without env or args is unchanged', () async {
    final out = Directory(p.join(tmp.path, 'dist'));
    await FlatpakPackager(runProcess: fakeRun).build(
      bundleDir: fakeBundle(),
      outDir: out,
      meta: const FlatpakMetadata(
        appId: 'com.example.App',
        command: 'homescreen',
      ),
    );
    expect(
      capturedLauncher,
      '#!/bin/sh\n'
      'exec /app/com.example.App/homescreen -b /app/com.example.App "\$@"\n',
    );
  });
  test('rejects an env name that is not a shell identifier', () async {
    expect(
      () => FlatpakPackager(runProcess: fakeRun).build(
        bundleDir: fakeBundle(),
        outDir: Directory(p.join(tmp.path, 'dist')),
        meta: const FlatpakMetadata(
          appId: 'com.example.App',
          command: 'homescreen',
          env: {'NOT-A-NAME': 'x'},
        ),
      ),
      throwsA(isA<FlatpakPackageException>()),
    );
  });

  test('rejects env and args that would break out of the launcher', () async {
    Future<void> build({
      Map<String, String> env = const {},
      List<String> args = const [],
    }) => FlatpakPackager(runProcess: fakeRun).build(
      bundleDir: fakeBundle(),
      outDir: Directory(p.join(tmp.path, 'dist')),
      meta: FlatpakMetadata(
        appId: 'com.example.App',
        command: 'homescreen',
        env: env,
        args: args,
      ),
    );
    // Closing the quoted word, or running a command at launch.
    expect(
      build(env: {'A': 'x" ; rm -rf /'}),
      throwsA(isA<FlatpakPackageException>()),
    );
    expect(
      build(env: {'A': r'$(id)'}),
      throwsA(isA<FlatpakPackageException>()),
    );
    expect(
      build(args: ['--flag=`id`']),
      throwsA(isA<FlatpakPackageException>()),
    );
    // Whitespace would silently split into two arguments.
    expect(
      build(args: ['--title=My App']),
      throwsA(isA<FlatpakPackageException>()),
    );
  });

  test(r'plain $VAR expansion in env is still allowed', () async {
    await FlatpakPackager(runProcess: fakeRun).build(
      bundleDir: fakeBundle(),
      outDir: Directory(p.join(tmp.path, 'dist')),
      meta: const FlatpakMetadata(
        appId: 'com.example.App',
        command: 'homescreen',
        env: {'XDG_DATA_HOME': r'$HOME/.local/share'},
      ),
    );
    expect(
      capturedLauncher,
      contains(r'export XDG_DATA_HOME="$HOME/.local/share"'),
    );
  });

  test('a path-shaped env name prepends, keeping runtime entries', () async {
    await FlatpakPackager(runProcess: fakeRun).build(
      bundleDir: fakeBundle(),
      outDir: Directory(p.join(tmp.path, 'dist')),
      meta: const FlatpakMetadata(
        appId: 'com.example.App',
        command: 'homescreen',
        env: {
          'LD_LIBRARY_PATH': '/app/com.example.App/lib',
          'XDG_DATA_DIRS': '/app/share',
          // Not path-shaped: assigned outright.
          'GIO_USE_PROXY_RESOLVER': 'dummy',
        },
      ),
    );
    final lines = capturedLauncher!.trim().split('\n');
    // Flatpak always sets LD_LIBRARY_PATH=/app/lib in the sandbox. Replacing it
    // would drop the runtime's own libraries, so the bundle's lib/ goes in
    // front of whatever is already there.
    const keep = r'${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}';
    expect(
      lines,
      contains('export LD_LIBRARY_PATH="/app/com.example.App/lib$keep"'),
    );
    expect(
      lines,
      contains(
        r'export XDG_DATA_DIRS="/app/share${XDG_DATA_DIRS:+:$XDG_DATA_DIRS}"',
      ),
    );
    expect(lines, contains('export GIO_USE_PROXY_RESOLVER="dummy"'));
  });

  test("onStaged edits the staged copy, never the caller's bundle", () async {
    final bundle = fakeBundle();
    await FlatpakPackager(runProcess: fakeRun).build(
      bundleDir: bundle,
      outDir: Directory(p.join(tmp.path, 'dist')),
      meta: const FlatpakMetadata(
        appId: 'com.example.App',
        command: 'homescreen',
      ),
      onStaged: (staged) async {
        // The fake `cp` stages only the top dir, so make lib/ here.
        Directory(p.join(staged.path, 'lib')).createSync(recursive: true);
        File(
          p.join(staged.path, 'lib', 'libvendored.so.1'),
        ).writeAsStringSync('elf');
      },
    );
    // The runnable also feeds --tar, --deploy and --run: a library chosen for
    // the flatpak runtime must not leak into it.
    expect(
      File(p.join(bundle.path, 'lib', 'libvendored.so.1')).existsSync(),
      isFalse,
    );
  });
  group('bundle path', () {
    Future<String> launcherFor(List<String> args) async {
      await FlatpakPackager(runProcess: fakeRun).build(
        bundleDir: fakeBundle(),
        outDir: Directory(p.join(tmp.path, 'dist')),
        meta: FlatpakMetadata(
          appId: 'com.example.App',
          command: 'homescreen',
          args: args,
        ),
      );
      return capturedLauncher!.trim().split('\n').last;
    }

    test(
      'defaults to -b <prefix>, which is what ivi-homescreen wants',
      () async {
        expect(
          await launcherFor(['--backend=wayland-egl']),
          'exec /app/com.example.App/homescreen -b /app/com.example.App '
          r'--backend=wayland-egl "$@"',
        );
      },
    );

    test('{bundle} in a flag replaces the default -b', () async {
      expect(
        await launcherFor(['--bundle={bundle}', '--quiet']),
        'exec /app/com.example.App/homescreen '
        r'--bundle=/app/com.example.App --quiet "$@"',
      );
    });

    test('{bundle} alone passes the path positionally', () async {
      expect(
        await launcherFor(['{bundle}']),
        r'exec /app/com.example.App/homescreen /app/com.example.App "$@"',
      );
    });
  });
  test('the module name is an identifier, not the display name', () async {
    await FlatpakPackager(runProcess: fakeRun).build(
      bundleDir: fakeBundle(),
      outDir: Directory(p.join(tmp.path, 'dist')),
      meta: const FlatpakMetadata(
        appId: 'com.example.RemoteManager',
        command: 'homescreen',
        appName: 'Flutter Remote Manager',
      ),
    );
    // flatpak-builder warns on a module name containing spaces and then fails
    // obscurely; the display name belongs in the .desktop, not here.
    expect(capturedManifest, contains('  - name: RemoteManager'));
    expect(capturedManifest, isNot(contains('name: Flutter Remote Manager')));
    // The human name still reaches the desktop entry.
    expect(capturedManifest, contains('com.example.RemoteManager.desktop'));
  });
}
