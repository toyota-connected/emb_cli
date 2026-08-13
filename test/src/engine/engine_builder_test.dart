import 'dart:io';

import 'package:emb_cli/src/cache/store.dart';
import 'package:emb_cli/src/engine/engine_builder.dart';
import 'package:emb_cli/src/engine/engine_toolchain.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  late Store store;
  late File script;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('emb-engine-builder-test-');
    store = Store(Directory(p.join(tmp.path, 'cache')));
    script = File(p.join(tmp.path, 'build-engine.sh'))
      ..writeAsStringSync('#!/bin/sh\n');
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  /// A fake recipe that writes a minimal engine-sdk tree into the out dir.
  EngineProcessRunner fakeRecipe({required List<int> callCount}) {
    return (exe, args, {workingDirectory, environment}) async {
      callCount[0]++;
      final out = Directory(args.last)..createSync(recursive: true);
      File(p.join(out.path, 'engine-sdk', 'libflutter_engine.so'))
        ..createSync(recursive: true)
        ..writeAsStringSync('elf');
      return ProcessResult(0, 0, '', '');
    };
  }

  test('builds once, adopts into the store, and reuses the cache', () async {
    final calls = [0];
    final builder = EngineBuilder(
      store: store,
      buildScript: script,
      runProcess: fakeRecipe(callCount: calls),
    );

    final first = await builder.build(
      commit: 'abc',
      arch: 'arm64',
      mode: 'release',
    );
    expect(first.status, EngineBuildStatus.built);
    expect(calls[0], 1);
    expect(first.storeRoot, isNotNull);
    expect(
      File(
        p.join(first.storeRoot!.path, 'engine-sdk', 'libflutter_engine.so'),
      ).existsSync(),
      isTrue,
    );

    final second = await builder.build(
      commit: 'abc',
      arch: 'arm64',
      mode: 'release',
    );
    expect(second.status, EngineBuildStatus.cached);
    expect(calls[0], 1, reason: 'a cache hit must not re-run the recipe');
  });

  test('reports unsupported when the recipe script is missing', () async {
    final builder = EngineBuilder(
      store: store,
      buildScript: File(p.join(tmp.path, 'does-not-exist.sh')),
    );
    final r = await builder.build(
      commit: 'abc',
      arch: 'arm64',
      mode: 'release',
    );
    expect(r.status, EngineBuildStatus.unsupported);
  });

  test('reports unsupported for a non-linux target', () async {
    final builder = EngineBuilder(store: store, buildScript: script);
    final r = await builder.build(
      commit: 'abc',
      arch: 'arm64',
      mode: 'release',
      profile: const ToolchainProfile(os: TargetOs.android, libc: Libc.bionic),
    );
    expect(r.status, EngineBuildStatus.unsupported);
  });

  test('reports failed when the recipe exits non-zero', () async {
    final builder = EngineBuilder(
      store: store,
      buildScript: script,
      runProcess: (exe, args, {workingDirectory, environment}) async =>
          ProcessResult(0, 2, '', 'boom'),
    );
    final r = await builder.build(
      commit: 'abc',
      arch: 'arm64',
      mode: 'release',
    );
    expect(r.status, EngineBuildStatus.failed);
  });

  test('offline build requires a fetched closure; fetch then build', () async {
    final phases = <String>[];
    EngineProcessRunner recorder() {
      return (exe, args, {workingDirectory, environment}) async {
        // args = [script, phase, mode, arch, commit, libc, out]
        final phase = args[1];
        phases.add(phase);
        final out = Directory(args.last)..createSync(recursive: true);
        if (phase == 'fetch') {
          Directory(
            p.join(out.path, 'flutter', 'engine', 'src'),
          ).createSync(recursive: true);
        } else {
          File(p.join(out.path, 'engine-sdk', 'libflutter_engine.so'))
            ..createSync(recursive: true)
            ..writeAsStringSync('elf');
        }
        return ProcessResult(0, 0, '', '');
      };
    }

    final builder = EngineBuilder(
      store: store,
      buildScript: script,
      runProcess: recorder(),
    );

    // No closure yet → an offline build is blocked (no network to fetch).
    final blocked = await builder.build(
      commit: 'abc',
      arch: 'arm64',
      mode: 'release',
      offline: true,
    );
    expect(blocked.status, EngineBuildStatus.unsupported);
    expect(phases, isEmpty);

    // Fetch the closure, then the offline build succeeds.
    final fetched = await builder.fetch(
      commit: 'abc',
      arch: 'arm64',
      mode: 'release',
    );
    expect(fetched.status, EngineBuildStatus.built);

    final built = await builder.build(
      commit: 'abc',
      arch: 'arm64',
      mode: 'release',
      offline: true,
    );
    expect(built.status, EngineBuildStatus.built);
    expect(phases, containsAllInOrder(<String>['fetch', 'build']));
  });

  test(
    'offline-strict refuses when no network namespace is available',
    () async {
      final builder = EngineBuilder(
        store: store,
        buildScript: script,
        runProcess: (exe, args, {workingDirectory, environment}) async {
          if (exe == 'unshare') return ProcessResult(0, 1, '', 'no userns');
          final out = Directory(args.last)..createSync(recursive: true);
          if (args[1] == 'fetch') {
            Directory(
              p.join(out.path, 'flutter', 'engine', 'src'),
            ).createSync(recursive: true);
          }
          return ProcessResult(0, 0, '', '');
        },
      );
      await builder.fetch(commit: 'abc', arch: 'arm64', mode: 'release');
      final r = await builder.build(
        commit: 'abc',
        arch: 'arm64',
        mode: 'release',
        strict: true,
      );
      expect(r.status, EngineBuildStatus.unsupported);
      expect(r.message, contains('network namespace'));
    },
  );

  test('offline-strict wraps the build in a network namespace', () async {
    var wrapped = false;
    final builder = EngineBuilder(
      store: store,
      buildScript: script,
      runProcess: (exe, args, {workingDirectory, environment}) async {
        if (exe == 'unshare' && args.length == 3) {
          return ProcessResult(0, 0, '', ''); // the availability probe
        }
        final out = Directory(args.last)..createSync(recursive: true);
        if (exe == 'unshare') {
          wrapped = true; // the netns-wrapped build phase
          File(p.join(out.path, 'engine-sdk', 'libflutter_engine.so'))
            ..createSync(recursive: true)
            ..writeAsStringSync('elf');
        } else {
          Directory(
            p.join(out.path, 'flutter', 'engine', 'src'),
          ).createSync(recursive: true); // the fetch phase
        }
        return ProcessResult(0, 0, '', '');
      },
    );
    await builder.fetch(commit: 'abc', arch: 'arm64', mode: 'release');
    final r = await builder.build(
      commit: 'abc',
      arch: 'arm64',
      mode: 'release',
      strict: true,
    );
    expect(wrapped, isTrue);
    expect(r.status, EngineBuildStatus.built);
  });

  test(
    'an alpine musl build passes the resolved sysroot to the recipe',
    () async {
      Map<String, String>? seenEnv;
      final sysroot = Directory(p.join(tmp.path, 'alpine-sysroot'))
        ..createSync(recursive: true);
      final builder = EngineBuilder(
        store: store,
        buildScript: script,
        alpineSysroot: ({required arch}) async => sysroot,
        runProcess: (exe, args, {workingDirectory, environment}) async {
          seenEnv = environment;
          final out = Directory(args.last)..createSync(recursive: true);
          File(p.join(out.path, 'engine-sdk', 'libflutter_engine.so'))
            ..createSync(recursive: true)
            ..writeAsStringSync('elf');
          return ProcessResult(0, 0, '', '');
        },
      );
      final r = await builder.build(
        commit: 'abc',
        arch: 'arm64',
        mode: 'release',
        profile: const ToolchainProfile(
          os: TargetOs.linux,
          libc: Libc.musl,
          sysrootId: 'alpine',
        ),
      );
      expect(r.status, EngineBuildStatus.built);
      expect(seenEnv?['EMB_SYSROOT_DIR'], sysroot.path);
      expect(seenEnv?['EMB_SYSROOT_ID'], 'alpine');
    },
  );
}
