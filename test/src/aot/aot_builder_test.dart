import 'dart:io';

import 'package:emb_cli/src/aot/aot_builder.dart';
import 'package:emb_cli/src/cross/process_runner.dart';
import 'package:emb_cli/src/host/host_info.dart';
import 'package:emb_cli/src/workspace/workspace.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

const _host = HostInfo(
  os: HostOs.linux,
  machineArch: 'x86_64',
  archAliases: {'x86_64', 'x64', 'amd64'},
  hostType: 'fedora',
  versionId: '43',
);

const _armHost = HostInfo(
  os: HostOs.linux,
  machineArch: 'aarch64',
  archAliases: {'arm64', 'aarch64'},
  hostType: 'fedora',
  versionId: '43',
);

const _riscvHost = HostInfo(
  os: HostOs.linux,
  machineArch: 'riscv64',
  archAliases: {'riscv64'},
  hostType: 'fedora',
  versionId: '43',
);

/// Records every process invocation and returns success; simulates the build
/// dir + app.dill appearing after `flutter build bundle`.
class _Recorder {
  _Recorder(this.app);
  final String app;
  final List<({String exe, List<String> args})> calls = [];

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
    calls.add((exe: p.basename(exe), args: args));
    if (args.isNotEmpty && args.first == 'build') {
      // Materialise .dart_tool/flutter_build/<hash>/ as flutter would.
      Directory(
        p.join(app, '.dart_tool', 'flutter_build', 'abc123'),
      ).createSync(recursive: true);
    }
    return const RunResult(0, '', '');
  }
}

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('emb_aot_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  // Native x86_64 build: target == host, so the resolver picks the host SDK
  // cache gen_snapshot directly (no artifact/probe needed).
  AotBuilder builder(Directory ws, _Recorder rec, {HostInfo host = _host}) =>
      AotBuilder(Workspace(ws), host: host, runProcess: rec.run);

  void writeApp(Directory app, {String name = 'myapp', bool config = true}) {
    app.createSync(recursive: true);
    File(p.join(app.path, 'pubspec.yaml')).writeAsStringSync('name: $name\n');
    // A real app has had `flutter pub get` run on it, so either it or its
    // workspace root owns a package_config.json. Tests that exercise the
    // missing-config path opt out.
    if (config) {
      File(p.join(app.path, '.dart_tool', 'package_config.json'))
        ..createSync(recursive: true)
        ..writeAsStringSync('{"configVersion":2,"packages":[]}');
    }
  }

  // Create a fake new-scheme SDK cache so the builder picks dartaotruntime +
  // frontend_server_aot and finds a host gen_snapshot. [engineDir] is the
  // host engine-artifacts dir name (`linux-x64`, `linux-arm64`, …).
  void writeSdk(Directory ws, {String engineDir = 'linux-x64'}) {
    final hostEngine = p.join(
      ws.path,
      'flutter',
      'bin',
      'cache',
      'artifacts',
      'engine',
      engineDir,
    );
    Directory(hostEngine).createSync(recursive: true);
    File(p.join(hostEngine, 'gen_snapshot')).writeAsStringSync('x');
    // The new-scheme frontend_server_aot snapshot lives in the Dart SDK and is
    // always host-arch — unlike the engine-artifacts copy, which is x64 even
    // inside the linux-arm64 bundle.
    final snapshots = p.join(
      ws.path,
      'flutter',
      'bin',
      'cache',
      'dart-sdk',
      'bin',
      'snapshots',
    );
    Directory(snapshots).createSync(recursive: true);
    File(
      p.join(snapshots, 'frontend_server_aot.dart.snapshot'),
    ).writeAsStringSync('x');
    Directory(
      p.join(
        ws.path,
        'flutter',
        'bin',
        'cache',
        'artifacts',
        'engine',
        'common',
        'flutter_patched_sdk_product',
      ),
    ).createSync(recursive: true);
  }

  test('runs build → kernel snapshot → gen_snapshot per mode', () async {
    final ws = Directory(p.join(tmp.path, 'ws'))..createSync();
    final app = Directory(p.join(tmp.path, 'app'));
    writeApp(app);
    writeSdk(ws);
    final rec = _Recorder(app.path);

    final result = await builder(
      ws,
      rec,
    ).build(appPath: app.path, modes: const ['release']);

    expect(result.success, isTrue);
    final exes = rec.calls.map((c) => c.exe).toList();
    expect(
      exes,
      containsAllInOrder(['flutter', 'dartaotruntime', 'gen_snapshot']),
    );

    // gen_snapshot emits the per-mode elf.
    final gen = rec.calls.firstWhere((c) => c.exe == 'gen_snapshot');
    expect(gen.args, contains('--snapshot_kind=app-aot-elf'));
    expect(gen.args, contains('--elf=libapp.so.release'));

    // kernel snapshot targets the product patched sdk for release + product vm.
    final kernel = rec.calls.firstWhere((c) => c.exe == 'dartaotruntime');
    expect(kernel.args, contains('-Ddart.vm.product=true'));
    expect(kernel.args, contains('package:myapp/main.dart'));
    expect(
      kernel.args.any((a) => a.contains('flutter_patched_sdk_product')),
      isTrue,
    );

    // x86_64 host: frontend_server comes from the Dart SDK (host-arch). The
    // gen_snapshot call above succeeding also proves _hostEngine resolved to
    // linux-x64, where writeSdk placed it.
    final frontend = kernel.args.firstWhere(
      (a) => a.endsWith('frontend_server_aot.dart.snapshot'),
    );
    expect(frontend, contains(p.join('dart-sdk', 'bin', 'snapshots')));
  });

  // Regression: on a non-x64 host the engine-artifacts dir is e.g.
  // `linux-arm64`/`linux-riscv64` (not `linux-x64`), and its
  // frontend_server_aot snapshot is an x64 binary the host dartaotruntime can't
  // run. The builder must resolve the host engine dir from the host arch and
  // take frontend_server from the Dart SDK (host-arch).
  for (final (host, engineDir) in [
    (_armHost, 'linux-arm64'),
    (_riscvHost, 'linux-riscv64'),
  ]) {
    test('${host.machineArch} host resolves $engineDir engine + '
        'dart-sdk frontend_server', () async {
      final ws = Directory(p.join(tmp.path, 'ws'))..createSync();
      final app = Directory(p.join(tmp.path, 'app'));
      writeApp(app);
      writeSdk(ws, engineDir: engineDir);
      final rec = _Recorder(app.path);

      final result = await builder(
        ws,
        rec,
        host: host,
      ).build(appPath: app.path, modes: const ['release']);

      // Succeeds only if _hostEngine resolved to [engineDir] (gen_snapshot is
      // written there) — proving the arch-derived path fix.
      expect(result.success, isTrue);

      final kernel = rec.calls.firstWhere((c) => c.exe == 'dartaotruntime');
      final frontend = kernel.args.firstWhere(
        (a) => a.endsWith('frontend_server_aot.dart.snapshot'),
      );
      // Host-arch snapshot from the Dart SDK, not the x64 engine copy.
      expect(frontend, contains(p.join('dart-sdk', 'bin', 'snapshots')));
      expect(frontend, isNot(contains(p.join('artifacts', 'engine'))));
    });
  }

  // `flutter build bundle` defaults --target-platform to android-arm whatever
  // the host is. For an app with code assets that means the build hooks run for
  // Android, and the engine — looking itself up as linux_<arch> at runtime —
  // finds no matching entry in NativeAssetsManifest.json.
  ({String exe, List<String> args}) bundleCall(_Recorder rec) =>
      rec.calls.firstWhere(
        (c) =>
            c.args.length > 1 && c.args[0] == 'build' && c.args[1] == 'bundle',
      );

  test(
    'names the plugin registrant relative to the app, not absolutely',
    () async {
      final ws = Directory(p.join(tmp.path, 'ws'))..createSync();
      final app = Directory(p.join(tmp.path, 'app'));
      writeApp(app);
      writeSdk(ws);
      // The registrant only gets passed when flutter_tools has generated it.
      final reg = Directory(p.join(app.path, '.dart_tool', 'flutter_build'))
        ..createSync(recursive: true);
      File(
        p.join(reg.path, 'dart_plugin_registrant.dart'),
      ).writeAsStringSync('');
      final rec = _Recorder(app.path);

      await builder(ws, rec).build(appPath: app.path, modes: const ['release']);

      final kernel = rec.calls.firstWhere((c) => c.exe == 'dartaotruntime');
      const uri =
          'org-dartlang-root:///.dart_tool/flutter_build/dart_plugin_registrant.dart';
      expect(kernel.args, containsAllInOrder(<String>['--source', uri]));
      expect(kernel.args, contains('-Dflutter.dart_plugin_registrant=$uri'));
      // The scheme only resolves if the compile is told what it is rooted at.
      expect(
        kernel.args,
        containsAllInOrder(<String>['--filesystem-root', app.path]),
      );
      expect(
        kernel.args,
        containsAllInOrder(<String>[
          '--filesystem-scheme',
          'org-dartlang-root',
        ]),
      );
      // The whole point: every argument naming the registrant is
      // scheme-relative, so the app path reaches nowhere the AOT
      // image could retain it.
      expect(
        kernel.args.where((a) => a.contains('dart_plugin_registrant')),
        everyElement(isNot(contains(app.path))),
      );
    },
  );

  group('obfuscation and stripping', () {
    /// Build [mode] and return the gen_snapshot argv.
    Future<({List<String> args, AotResult result})> gen(
      Directory tmpDir,
      String mode, {
      bool? obfuscate,
      bool strip = true,
    }) async {
      final ws = Directory(p.join(tmpDir.path, 'ws'))..createSync();
      final app = Directory(p.join(tmpDir.path, 'app'));
      writeApp(app);
      writeSdk(ws);
      final rec = _Recorder(app.path);
      final result = await builder(ws, rec).build(
        appPath: app.path,
        modes: [mode],
        obfuscate: obfuscate,
        strip: strip,
      );
      return (
        args: rec.calls.firstWhere((c) => c.exe == 'gen_snapshot').args,
        result: result,
      );
    }

    // gen_snapshot errors on --save-obfuscation-map without --obfuscate, and
    // an obfuscated image with no map can never be symbolized — so the two
    // always travel together.
    test('release obfuscates and always saves the map', () async {
      final g = await gen(tmp, 'release');
      expect(g.args, contains('--obfuscate'));
      expect(
        g.args,
        contains(
          '--save-obfuscation-map=libapp.so.release.obfuscation-map.json',
        ),
      );
      expect(
        g.result.modes.single.obfuscationMap,
        endsWith('libapp.so.release.obfuscation-map.json'),
      );
    });

    // profile exists to be inspected; --track-widget-creation is passed there
    // so DevTools can name widgets, which obfuscating the image undoes.
    test('profile does not obfuscate by default', () async {
      final g = await gen(tmp, 'profile');
      expect(g.args, isNot(contains('--obfuscate')));
      expect(
        g.args.any((a) => a.startsWith('--save-obfuscation-map')),
        isFalse,
      );
      expect(g.result.modes.single.obfuscationMap, isNull);
    });

    test('--no-obfuscate drops both flags on release', () async {
      final g = await gen(tmp, 'release', obfuscate: false);
      expect(g.args, isNot(contains('--obfuscate')));
      expect(
        g.args.any((a) => a.startsWith('--save-obfuscation-map')),
        isFalse,
      );
      expect(g.result.modes.single.obfuscationMap, isNull);
    });

    test('--obfuscate opts profile in, with a map', () async {
      final g = await gen(tmp, 'profile', obfuscate: true);
      expect(g.args, contains('--obfuscate'));
      expect(
        g.args,
        contains(
          '--save-obfuscation-map=libapp.so.profile.obfuscation-map.json',
        ),
      );
    });

    test('strips by default', () async {
      expect((await gen(tmp, 'release')).args, contains('--strip'));
    });

    test('--no-strip opts out when not obfuscating', () async {
      final g = await gen(tmp, 'release', obfuscate: false, strip: false);
      expect(g.args, isNot(contains('--strip')));
      expect(g.args, isNot(contains('--obfuscate')));
    });

    test('profile takes --no-strip without opting out of anything', () async {
      // profile does not obfuscate by default, so --no-strip alone is fine.
      final g = await gen(tmp, 'profile', strip: false);
      expect(g.args, isNot(contains('--strip')));
      expect(g.args, isNot(contains('--obfuscate')));
    });
  });

  group('obfuscate without strip is refused', () {
    /// Build [mode] and return the result plus whether gen_snapshot ran.
    Future<({AotResult result, bool ranGen})> attempt(
      Directory tmpDir,
      String mode, {
      bool? obfuscate,
    }) async {
      final ws = Directory(p.join(tmpDir.path, 'ws'))..createSync();
      final app = Directory(p.join(tmpDir.path, 'app'));
      writeApp(app);
      writeSdk(ws);
      final rec = _Recorder(app.path);
      final result = await builder(ws, rec).build(
        appPath: app.path,
        modes: [mode],
        obfuscate: obfuscate,
        strip: false,
      );
      return (
        result: result,
        ranGen: rec.calls.any((c) => c.exe == 'gen_snapshot'),
      );
    }

    // gen_snapshot leaves the DWARF unobfuscated when not stripping, so the
    // image still carries the identifiers obfuscation was asked to remove.
    test(
      'explicit --obfuscate with --no-strip fails before any work',
      () async {
        final a = await attempt(tmp, 'release', obfuscate: true);
        expect(a.result.success, isFalse);
        expect(a.ranGen, isFalse, reason: 'must fail before compiling');
        expect(a.result.modes.single.message, contains('--no-obfuscate'));
      },
    );

    test('release --no-strip alone fails, naming the default', () async {
      final a = await attempt(tmp, 'release');
      expect(a.result.success, isFalse);
      expect(a.result.modes.single.message, contains('obfuscates by default'));
    });

    test('only the offending mode fails', () async {
      final ws = Directory(p.join(tmp.path, 'ws'))..createSync();
      final app = Directory(p.join(tmp.path, 'app'));
      writeApp(app);
      writeSdk(ws);
      final rec = _Recorder(app.path);
      final r = await builder(ws, rec).build(
        appPath: app.path,
        modes: const ['profile', 'release'],
        strip: false,
      );
      final byMode = {for (final m in r.modes) m.mode: m};
      expect(byMode['profile']!.success, isTrue);
      expect(byMode['release']!.success, isFalse);
    });
  });

  test('AOT build targets linux for the requested arch', () async {
    final ws = Directory(p.join(tmp.path, 'ws'))..createSync();
    final app = Directory(p.join(tmp.path, 'app'));
    writeApp(app);
    writeSdk(ws);
    final rec = _Recorder(app.path);

    await builder(
      ws,
      rec,
    ).build(appPath: app.path, modes: ['release'], arch: 'arm64');

    expect(
      bundleCall(rec).args,
      containsAllInOrder(<String>['--target-platform', 'linux-arm64']),
    );
  });

  test('buildAssets targets linux for the requested arch', () async {
    final ws = Directory(p.join(tmp.path, 'ws'))..createSync();
    final app = Directory(p.join(tmp.path, 'app'));
    writeApp(app);
    writeSdk(ws);
    final rec = _Recorder(app.path);

    await builder(
      ws,
      rec,
    ).buildAssets(appPath: app.path, mode: 'debug', arch: 'x86_64');

    expect(
      bundleCall(rec).args,
      containsAllInOrder(<String>['--target-platform', 'linux-x64']),
    );
  });

  test('omits --target-platform where Flutter has no linux target', () async {
    final ws = Directory(p.join(tmp.path, 'ws'))..createSync();
    final app = Directory(p.join(tmp.path, 'app'));
    writeApp(app);
    writeSdk(ws);
    final rec = _Recorder(app.path);

    // armv7 has engine artifacts but no Flutter linux-* token; passing one
    // would be rejected, so the flag is left off rather than guessed.
    await builder(
      ws,
      rec,
    ).buildAssets(appPath: app.path, mode: 'release', arch: 'armv7hf');

    expect(bundleCall(rec).args, isNot(contains('--target-platform')));
  });

  group('package_config resolution', () {
    /// The `--packages` value the kernel step was invoked with.
    String? packagesArg(_Recorder rec) {
      for (final c in rec.calls) {
        final i = c.args.indexOf('--packages');
        if (i != -1 && i + 1 < c.args.length) return c.args[i + 1];
      }
      return null;
    }

    void writeConfig(Directory dir) =>
        File(p.join(dir.path, '.dart_tool', 'package_config.json'))
          ..createSync(recursive: true)
          ..writeAsStringSync('{"configVersion":2,"packages":[]}');

    // A pub workspace resolves once at the root; members get a .dart_tool with
    // no config of their own. The app's parent here is the library package, not
    // the root -- the packages/<pkg>/example shape flutterfire, plus_plugins and
    // FirebaseUI-Flutter all use.
    test('finds the config at the pub workspace root', () async {
      final ws = Directory(p.join(tmp.path, 'ws'))..createSync();
      writeSdk(ws);
      final root = Directory(p.join(tmp.path, 'repo'))..createSync();
      File(p.join(root.path, 'pubspec.yaml')).writeAsStringSync(
        'name: repo_root\nworkspace:\n  - packages/lib/example\n',
      );
      writeConfig(root);
      final lib = Directory(p.join(root.path, 'packages', 'lib'))
        ..createSync(recursive: true);
      File(p.join(lib.path, 'pubspec.yaml')).writeAsStringSync('name: lib\n');
      final app = Directory(p.join(lib.path, 'example'));
      writeApp(app, config: false);
      File(
        p.join(app.path, 'pubspec.yaml'),
      ).writeAsStringSync('name: myapp\nresolution: workspace\n');

      final rec = _Recorder(app.path);
      final result = await builder(
        ws,
        rec,
      ).build(appPath: app.path, modes: const ['release']);

      expect(result.success, isTrue, reason: result.modes.first.message);
      expect(
        packagesArg(rec),
        p.join(root.path, '.dart_tool', 'package_config.json'),
      );
    });

    // The walk must not climb past the workspace root into an unrelated config
    // -- a stray ~/.dart_tool/package_config.json would otherwise be handed to
    // --packages and produce a compile error pointing nowhere near the cause.
    test(
      'stops at the pub workspace root rather than taking a stray',
      () async {
        final ws = Directory(p.join(tmp.path, 'ws'))..createSync();
        writeSdk(ws);
        final stray = Directory(p.join(tmp.path, 'stray'))..createSync();
        writeConfig(stray);
        final root = Directory(p.join(stray.path, 'repo'))..createSync();
        File(
          p.join(root.path, 'pubspec.yaml'),
        ).writeAsStringSync('name: repo_root\nworkspace:\n  - app\n');
        final app = Directory(p.join(root.path, 'app'));
        writeApp(app, config: false);

        final rec = _Recorder(app.path);
        final result = await builder(
          ws,
          rec,
        ).build(appPath: app.path, modes: const ['release']);

        expect(result.success, isFalse);
        expect(
          result.modes.first.message,
          contains('no .dart_tool/package_config.json'),
        );
        expect(
          packagesArg(rec),
          isNull,
          reason: 'the stray config above the root must never be used',
        );
      },
    );

    test('a missing config is reported, not thrown', () async {
      final ws = Directory(p.join(tmp.path, 'ws'))..createSync();
      writeSdk(ws);
      final app = Directory(p.join(tmp.path, 'lonely', 'app'));
      writeApp(app, config: false);

      final rec = _Recorder(app.path);
      final result = await builder(
        ws,
        rec,
      ).build(appPath: app.path, modes: const ['release']);

      expect(result.success, isFalse);
      expect(result.modes.first.message, contains('flutter pub get'));
    });

    test('an app that owns its config uses it', () async {
      final ws = Directory(p.join(tmp.path, 'ws'))..createSync();
      writeSdk(ws);
      final app = Directory(p.join(tmp.path, 'solo'));
      writeApp(app);
      writeConfig(app);

      final rec = _Recorder(app.path);
      final result = await builder(
        ws,
        rec,
      ).build(appPath: app.path, modes: const ['release']);

      expect(result.success, isTrue, reason: result.modes.first.message);
      expect(
        packagesArg(rec),
        p.join(app.path, '.dart_tool', 'package_config.json'),
      );
    });
  });

  test('fails cleanly when pubspec has no name', () async {
    final ws = Directory(p.join(tmp.path, 'ws'))..createSync();
    final app = Directory(p.join(tmp.path, 'app'))..createSync();
    File(
      p.join(app.path, 'pubspec.yaml'),
    ).writeAsStringSync('description: x\n');
    writeSdk(ws);

    final result = await builder(
      ws,
      _Recorder(app.path),
    ).build(appPath: app.path);
    expect(result.success, isFalse);
  });
}
