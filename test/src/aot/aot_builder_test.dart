import 'dart:io';

import 'package:emb_cli/src/aot/aot_builder.dart';
import 'package:emb_cli/src/cache/cas.dart';
import 'package:emb_cli/src/cache/store.dart';
import 'package:emb_cli/src/cross/process_runner.dart';
import 'package:emb_cli/src/engine/engine_artifacts.dart';
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

  /// Every executable and argument seen, unshortened, for tests that care
  /// which copy of a tool ran.
  final List<String> paths = [];

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
    paths.addAll([exe, ...args]);
    if (args.isNotEmpty && args.first == 'build') {
      // Materialise .dart_tool/flutter_build/<hash>/ as flutter would.
      Directory(
        p.join(app, '.dart_tool', 'flutter_build', 'abc123'),
      ).createSync(recursive: true);
    }
    return const RunResult(0, '', '');
  }
}

/// A [Cas] that hands back one local tarball and counts the downloads it stood
/// in for.
class _FakeCas extends Cas {
  _FakeCas(super.root, this.blob);
  final File blob;
  int calls = 0;
  @override
  Future<File> ensure(String url, {String? expectedSha}) async {
    calls++;
    return blob;
  }
}

/// An [EngineArtifacts] that never touches the network: records each fetch and
/// "materializes" an engine SDK holding [genRel] for the modes in [publishes].
class _FakeEngine extends EngineArtifacts {
  _FakeEngine(
    super.workspace, {
    required this.genRel,
    this.publishes = const {'release', 'profile'},
    this.cached = const {},
  });

  /// gen_snapshot path inside the SDK: `clang_x64/bin/…` (cross) or `bin/…`.
  final String genRel;
  final Set<String> publishes;

  /// Modes whose SDK is already in the store (a fetch only re-links it).
  final Set<String> cached;
  final List<String> cacheProbes = [];
  final List<({String runtime, String arch})> fetches = [];
  bool closed = false;

  @override
  bool isCached({
    required String runtime,
    required String arch,
    required String commit,
  }) {
    cacheProbes.add(runtime);
    return cached.contains(runtime);
  }

  @override
  Future<EngineFetchResult> fetch({
    required String runtime,
    required String arch,
    required String commit,
    bool clean = false,
  }) async {
    fetches.add((runtime: runtime, arch: arch));
    if (!publishes.contains(runtime)) {
      return EngineFetchResult(
        runtime: runtime,
        arch: arch,
        status: EngineFetchStatus.unavailable,
        message: 'No published prebuilt for $runtime/$arch@$commit',
      );
    }
    File(
        p.join(
          workspace.platformDir('flutter-engine').path,
          commit,
          'engine-sdk-$runtime-$arch',
          'engine-sdk',
          genRel,
        ),
      )
      ..createSync(recursive: true)
      ..writeAsStringSync('x');
    return EngineFetchResult(
      runtime: runtime,
      arch: arch,
      status: EngineFetchStatus.fetched,
    );
  }

  @override
  void close() {
    closed = true;
    super.close();
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

  group('gen_snapshot fetch fallback', () {
    const commit = 'abc123';
    const bothModes = ['release', 'profile'];

    /// A workspace that knows its engine commit and has no engine SDK staged.
    Directory workspaceAt(String name, {bool hostGen = true}) {
      final ws = Directory(p.join(tmp.path, name))..createSync();
      writeSdk(ws);
      File(p.join(ws.path, 'flutter', 'bin', 'internal', 'engine.version'))
        ..createSync(recursive: true)
        ..writeAsStringSync('$commit\n');
      if (!hostGen) {
        File(
          p.join(
            ws.path,
            'flutter',
            'bin',
            'cache',
            'artifacts',
            'engine',
            'linux-x64',
            'gen_snapshot',
          ),
        ).deleteSync();
      }
      return ws;
    }

    /// Every gen_snapshot path the build invoked, relative to [ws].
    Set<String> gensUsed(_Recorder rec, Directory ws) => {
      for (final c in rec.paths)
        if (p.basename(c) == 'gen_snapshot') p.relative(c, from: ws.path),
    };

    // The Flutter SDK's gen_snapshot is already on disk, so a native build
    // must not download one. It used to fetch every mode first.
    test('a native build with a host gen_snapshot downloads nothing', () async {
      final ws = workspaceAt('ws');
      final app = Directory(p.join(tmp.path, 'app'));
      writeApp(app);
      final rec = _Recorder(app.path);
      late _FakeEngine engine;
      final steps = <String>[];

      final result = await AotBuilder(
        Workspace(ws),
        host: _host,
        runProcess: rec.run,
        engineFactory: (w) => engine = _FakeEngine(w, genRel: 'bin/x'),
      ).build(appPath: app.path, onStep: steps.add);

      expect(result.success, isTrue);
      expect(engine.cacheProbes, bothModes);
      expect(engine.fetches, isEmpty);
      expect(engine.closed, isTrue);
      expect(steps, isNot(contains('Fetching engine SDK for gen_snapshot')));
      expect(gensUsed(rec, ws), {
        p.join(
          'flutter',
          'bin',
          'cache',
          'artifacts',
          'engine',
          'linux-x64',
          'gen_snapshot',
        ),
      });
    });

    // Container re-entry: `emb engine` ran in an earlier container, so the SDK
    // is in the mounted store and only the workspace link is gone. The build
    // must pick the same gen_snapshot it would with the link in place, not
    // drift to the host copy because a symlink was ephemeral.
    test('a native build re-links a cached SDK over the host copy', () async {
      final ws = workspaceAt('ws');
      final app = Directory(p.join(tmp.path, 'app'));
      writeApp(app);
      final rec = _Recorder(app.path);
      late _FakeEngine engine;

      final result = await AotBuilder(
        Workspace(ws),
        host: _host,
        runProcess: rec.run,
        engineFactory: (w) => engine = _FakeEngine(
          w,
          genRel: p.join('bin', 'gen_snapshot'),
          // Only profile is cached: release is skipped, not downloaded.
          cached: const {'profile'},
        ),
      ).build(appPath: app.path);

      expect(result.success, isTrue);
      expect(engine.fetches, [(runtime: 'profile', arch: 'x86_64')]);
      expect(gensUsed(rec, ws), {
        p.join(
          '.config',
          'flutter_workspace',
          'flutter-engine',
          commit,
          'engine-sdk-profile-x86_64',
          'engine-sdk',
          'bin',
          'gen_snapshot',
        ),
      });
    });

    // One gen_snapshot serves every mode: the first SDK that yields one ends
    // the search, so profile is never fetched.
    test('a cross build fetches until the scan hits, then stops', () async {
      final ws = workspaceAt('ws');
      final app = Directory(p.join(tmp.path, 'app'));
      writeApp(app);
      final rec = _Recorder(app.path);
      late _FakeEngine engine;

      final result =
          await AotBuilder(
            Workspace(ws),
            host: _host,
            runProcess: rec.run,
            engineFactory: (w) => engine = _FakeEngine(
              w,
              genRel: p.join('clang_x64', 'bin', 'gen_snapshot'),
            ),
          ).build(
            appPath: app.path,
            // An alias: the fetch and the scan must agree on the token.
            arch: 'aarch64',
          );

      expect(result.success, isTrue);
      expect(engine.fetches, [(runtime: 'release', arch: 'arm64')]);
      // Cross has no host copy to fall back on: it fetches whether or not the
      // store has the SDK, so the cache is never even asked.
      expect(engine.cacheProbes, isEmpty);
      expect(engine.closed, isTrue);
      expect(gensUsed(rec, ws), {
        p.join(
          '.config',
          'flutter_workspace',
          'flutter-engine',
          commit,
          'engine-sdk-release-arm64',
          'engine-sdk',
          'clang_x64',
          'bin',
          'gen_snapshot',
        ),
      });
    });

    test('a mode with no prebuilt is reported and the next is tried', () async {
      final ws = workspaceAt('ws');
      final app = Directory(p.join(tmp.path, 'app'));
      writeApp(app);
      final rec = _Recorder(app.path);
      late _FakeEngine engine;
      final steps = <String>[];

      final result = await AotBuilder(
        Workspace(ws),
        host: _host,
        runProcess: rec.run,
        engineFactory: (w) => engine = _FakeEngine(
          w,
          genRel: p.join('clang_x64', 'bin', 'gen_snapshot'),
          publishes: const {'profile'},
        ),
      ).build(appPath: app.path, arch: 'arm64', onStep: steps.add);

      expect(result.success, isTrue);
      expect(engine.fetches.map((f) => f.runtime), bothModes);
      expect(
        steps,
        contains(
          'engine SDK release/arm64: '
          'No published prebuilt for release/arm64@$commit',
        ),
      );
    });

    // Nothing published and no host copy that can target arm64: the build
    // fails, and every failed fetch is named on the way.
    test('a cross build with nothing published fails, loudly', () async {
      final ws = workspaceAt('ws');
      final app = Directory(p.join(tmp.path, 'app'));
      writeApp(app);
      final rec = _Recorder(app.path);
      late _FakeEngine engine;
      final steps = <String>[];

      final result = await AotBuilder(
        Workspace(ws),
        host: _host,
        runProcess: rec.run,
        engineFactory: (w) =>
            engine = _FakeEngine(w, genRel: 'x', publishes: const {}),
      ).build(appPath: app.path, arch: 'arm64', onStep: steps.add);

      expect(result.success, isFalse);
      expect(engine.fetches.map((f) => f.runtime), bothModes);
      expect(engine.closed, isTrue);
      expect(steps.where((s) => s.startsWith('engine SDK ')), hasLength(2));
      expect(gensUsed(rec, ws), isEmpty);
    });

    // No host copy either (a fresh container before the Flutter cache is
    // warm): now the fetch is the only source, native or not.
    test('a native build with no host gen_snapshot fetches one', () async {
      final ws = workspaceAt('ws', hostGen: false);
      final app = Directory(p.join(tmp.path, 'app'));
      writeApp(app);
      final rec = _Recorder(app.path);
      late _FakeEngine engine;

      final result = await AotBuilder(
        Workspace(ws),
        host: _host,
        runProcess: rec.run,
        engineFactory: (w) =>
            engine = _FakeEngine(w, genRel: p.join('bin', 'gen_snapshot')),
      ).build(appPath: app.path);

      expect(result.success, isTrue);
      expect(engine.fetches, [(runtime: 'release', arch: 'x86_64')]);
      expect(gensUsed(rec, ws).single, contains('engine-sdk-release-x86_64'));
    });
  });

  // The same paths through the real EngineArtifacts and Store, with only the
  // download faked: the fake above cannot show that fetch, the link name and
  // the scan agree with each other.
  group('gen_snapshot fetch fallback, real store', () {
    const commit = 'abc123';
    late Directory cache;
    late _FakeCas cas;
    late Directory ws;
    late Directory app;
    late _Recorder rec;

    setUp(() async {
      cache = Directory(p.join(tmp.path, 'cache'))..createSync();
      // An engine SDK tarball laid out as the published ones are: a native
      // bin/gen_snapshot and the clang_x64 cross one side by side.
      final src = Directory(p.join(tmp.path, 'sdk'))..createSync();
      for (final rel in [
        'data/icudtl.dat',
        'lib/libflutter_engine.so',
        'bin/gen_snapshot',
        'clang_x64/bin/gen_snapshot',
      ]) {
        File(p.join(src.path, 'engine-sdk', rel))
          ..createSync(recursive: true)
          ..writeAsStringSync('x');
      }
      final blob = File(p.join(tmp.path, 'engine.tar.gz'));
      final rc = await Process.run('tar', [
        '-czf',
        blob.path,
        '-C',
        src.path,
        'engine-sdk',
      ]);
      expect(rc.exitCode, 0, reason: '${rc.stderr}');
      cas = _FakeCas(cache, blob);

      ws = Directory(p.join(tmp.path, 'ws'))..createSync();
      writeSdk(ws);
      File(p.join(ws.path, 'flutter', 'bin', 'internal', 'engine.version'))
        ..createSync(recursive: true)
        ..writeAsStringSync('$commit\n');
      app = Directory(p.join(tmp.path, 'app'));
      writeApp(app);
      rec = _Recorder(app.path);
    });

    EngineArtifacts engine(Workspace w) =>
        EngineArtifacts(w, cas: cas, store: Store(cache));

    AotBuilder aot() => AotBuilder(
      Workspace(ws),
      host: _host,
      runProcess: rec.run,
      engineFactory: engine,
    );

    String sdkGen(String mode, String token, String rel) => p.join(
      '.config',
      'flutter_workspace',
      'flutter-engine',
      commit,
      'engine-sdk-$mode-$token',
      'engine-sdk',
      rel,
    );

    Set<String> gensUsed() => {
      for (final c in rec.paths)
        if (p.basename(c) == 'gen_snapshot') p.relative(c, from: ws.path),
    };

    test('cross, cold store: one download, the clang_x64 copy', () async {
      final result = await aot().build(appPath: app.path, arch: 'aarch64');

      expect(result.success, isTrue);
      expect(cas.calls, 1, reason: 'release only; profile is not needed');
      expect(gensUsed(), {
        sdkGen('release', 'arm64', p.join('clang_x64', 'bin', 'gen_snapshot')),
      });
    });

    test('cross, warm store, link gone: re-linked, no download', () async {
      final seed = engine(Workspace(ws));
      await seed.fetch(runtime: 'release', arch: 'arm64', commit: commit);
      seed.close();
      Directory(
        p.join(Workspace(ws).platformDir('flutter-engine').path, commit),
      ).deleteSync(recursive: true);
      cas.calls = 0;

      final result = await aot().build(appPath: app.path, arch: 'arm64');

      expect(result.success, isTrue);
      expect(cas.calls, 0);
      expect(gensUsed(), {
        sdkGen('release', 'arm64', p.join('clang_x64', 'bin', 'gen_snapshot')),
      });
    });

    test('native, cold store: host copy, no download', () async {
      final result = await aot().build(appPath: app.path);

      expect(result.success, isTrue);
      expect(cas.calls, 0);
      expect(gensUsed().single, contains(p.join('engine', 'linux-x64')));
    });

    test('native, warm store, link gone: the SDK copy, no download', () async {
      final seed = engine(Workspace(ws));
      await seed.fetch(runtime: 'release', arch: 'x86_64', commit: commit);
      seed.close();
      Directory(
        p.join(Workspace(ws).platformDir('flutter-engine').path, commit),
      ).deleteSync(recursive: true);
      cas.calls = 0;

      final result = await aot().build(appPath: app.path);

      expect(result.success, isTrue);
      expect(cas.calls, 0);
      expect(gensUsed(), {
        sdkGen('release', 'x86_64', p.join('bin', 'gen_snapshot')),
      });
    });
  });

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
