import 'dart:io';

import 'package:emb_cli/src/cross/cross_builder.dart';
import 'package:emb_cli/src/cross/cross_profile.dart';
import 'package:emb_cli/src/cross/cross_target.dart';
import 'package:emb_cli/src/cross/overlay_builder.dart';
import 'package:emb_cli/src/cross/process_runner.dart';
import 'package:emb_cli/src/workspace/workspace.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

const _profile = CrossProfile(
  providerName: 'arm-gnu',
  targetTriple: 'aarch64-none-linux-gnu',
  cc: '/tc/bin/aarch64-none-linux-gnu-gcc',
  cxx: '/tc/bin/aarch64-none-linux-gnu-g++',
  ar: 'ar',
  strip: 'strip',
  targetSysroot: '/sr',
  pkgConfig: PkgConfig(sysrootDir: '/sr', libdir: ['/sr/usr/lib/pkgconfig']),
  cmakeToolchainFile: '/tc.cmake',
  mesonCrossFile: '/c.cross',
  extraEnv: {'CC': 'aarch64-none-linux-gnu-gcc'},
);

/// A recording fake [process runner] that fails the steps named in [failOn].
({ProcessRunner run, List<List<String>> calls, List<Map<String, String>?> envs})
recorder({bool Function(String exe, List<String> args)? failOn}) {
  final calls = <List<String>>[];
  final envs = <Map<String, String>?>[];
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
    calls.add([exe, ...args]);
    envs.add(environment);
    final fail = failOn?.call(exe, args) ?? false;
    return RunResult(fail ? 1 : 0, '', 'boom');
  }

  return (run: run, calls: calls, envs: envs);
}

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('emb_xbuild_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  Directory dir(String name) => Directory(p.join(tmp.path, name));

  test('cmake: configures with the toolchain file + defines, then builds', () {
    final rec = recorder();
    return CrossBuilder(_profile, runProcess: rec.run)
        .build(
          sourceDir: dir('src'),
          buildDir: dir('b'),
          generator: CrossGenerator.cmake,
          defines: {'BUILD_BACKEND_WAYLAND_EGL': 'ON'},
        )
        .then((r) {
          expect(r.success, isTrue);
          final cfg = rec.calls.firstWhere(
            (c) => c.first == 'cmake' && c.contains('-S'),
          );
          expect(cfg, contains('-DCMAKE_TOOLCHAIN_FILE=/tc.cmake'));
          expect(cfg, contains('-DCMAKE_BUILD_TYPE=Release'));
          expect(cfg, contains('-DBUILD_BACKEND_WAYLAND_EGL=ON'));
          expect(
            rec.calls.any((c) => c.first == 'cmake' && c.contains('--build')),
            isTrue,
          );
          // The profile's build env is applied to every step.
          expect(rec.envs.first!['CC'], 'aarch64-none-linux-gnu-gcc');
        });
  });

  test('hostToolBins: prepended to the build PATH', () async {
    final rec = recorder();
    final r =
        await CrossBuilder(
          _profile,
          runProcess: rec.run,
          hostToolBins: ['/emb/host-tools/usr/bin'],
        ).build(
          sourceDir: dir('src'),
          buildDir: dir('b'),
          generator: CrossGenerator.cmake,
        );
    expect(r.success, isTrue);
    // The cross build's find_program searches the host PATH, so a host-augment
    // bin dir must lead it on every step.
    final env = rec.envs.first!;
    expect(env['PATH'], startsWith('/emb/host-tools/usr/bin:'));
  });

  test('launcher: injects COMPILER_LAUNCHER + CCACHE_BASEDIR', () async {
    final rec = recorder();
    final r =
        await CrossBuilder(
          _profile,
          runProcess: rec.run,
          launcher: 'ccache',
          ccacheBaseDir: '/ws',
        ).build(
          sourceDir: dir('src'),
          buildDir: dir('b'),
          generator: CrossGenerator.cmake,
        );
    expect(r.success, isTrue);
    final cfg = rec.calls.firstWhere(
      (c) => c.first == 'cmake' && c.contains('-S'),
    );
    expect(cfg, contains('-DCMAKE_C_COMPILER_LAUNCHER=ccache'));
    expect(cfg, contains('-DCMAKE_CXX_COMPILER_LAUNCHER=ccache'));
    expect(rec.envs.first!['CCACHE_BASEDIR'], '/ws');
  });

  test('no launcher: omits the COMPILER_LAUNCHER defines', () async {
    final rec = recorder();
    await CrossBuilder(_profile, runProcess: rec.run).build(
      sourceDir: dir('src'),
      buildDir: dir('b'),
      generator: CrossGenerator.cmake,
    );
    final cfg = rec.calls.firstWhere(
      (c) => c.first == 'cmake' && c.contains('-S'),
    );
    expect(cfg.any((a) => a.contains('COMPILER_LAUNCHER')), isFalse);
    expect(rec.envs.first!.containsKey('CCACHE_BASEDIR'), isFalse);
  });

  test('overlay: layers augment search paths onto the cmake build', () async {
    final rec = recorder();
    const overlay = OverlayPaths(
      prefix: '/ws/overlay',
      includeDirs: ['/ws/overlay/usr/include'],
      libDirs: ['/ws/overlay/usr/lib'],
      pkgConfigDirs: ['/ws/overlay/usr/lib/pkgconfig'],
    );
    final r =
        await CrossBuilder(
          _profile,
          runProcess: rec.run,
          overlay: overlay,
        ).build(
          sourceDir: dir('src'),
          buildDir: dir('b'),
          generator: CrossGenerator.cmake,
        );
    expect(r.success, isTrue);
    final cfg = rec.calls.firstWhere(
      (c) => c.first == 'cmake' && c.contains('-S'),
    );
    // find_package/find_library search the overlay prefix (+ the sysroot).
    expect(cfg, contains('-DCMAKE_FIND_ROOT_PATH=/ws/overlay'));
    expect(cfg, contains('-DCMAKE_PREFIX_PATH=/ws/overlay'));
    final env = rec.envs.first!;
    // pkg-config finds the module (detection) — but its reported -I is
    // sysroot-rebased and wrong for an out-of-sysroot overlay, so the real
    // include/lib dirs are injected as compiler flags the compiler honors.
    expect(
      env['PKG_CONFIG_LIBDIR'],
      '/ws/overlay/usr/lib/pkgconfig:/sr/usr/lib/pkgconfig',
    );
    expect(env['PKG_CONFIG_SYSROOT_DIR'], '/sr');
    expect(env['CFLAGS'], contains('-I/ws/overlay/usr/include'));
    expect(env['CXXFLAGS'], contains('-I/ws/overlay/usr/include'));
    expect(env['LDFLAGS'], contains('-L/ws/overlay/usr/lib'));
  });

  test(
    'meson: sets up with the cross file + options, then runs ninja',
    () async {
      final rec = recorder();
      final r = await CrossBuilder(_profile, runProcess: rec.run).build(
        sourceDir: dir('src'),
        buildDir: dir('b'),
        generator: CrossGenerator.meson,
        defines: {'backend': 'drm-gl'},
      );
      expect(r.success, isTrue);
      final setup = rec.calls.firstWhere((c) => c.first == 'meson');
      expect(setup, containsAll(['--cross-file', '/c.cross']));
      expect(setup, containsAll(['--buildtype', 'release']));
      expect(setup, contains('-Dbackend=drm-gl'));
      expect(rec.calls.any((c) => c.first == 'ninja'), isTrue);
    },
  );

  // A fake host-tool resolver so the tests don't depend on the runner's tools.
  String? fakeHostTool(String tool) => '/opt/host/$tool';

  test('hostTools: cmake is invoked by the resolved host path', () async {
    final rec = recorder();
    final r =
        await CrossBuilder(
          _profile,
          runProcess: rec.run,
          hostTools: true,
          resolveHostTool: fakeHostTool,
        ).build(
          sourceDir: dir('src'),
          buildDir: dir('b'),
          generator: CrossGenerator.cmake,
        );
    expect(r.success, isTrue);
    final cfg = rec.calls.firstWhere((c) => c.contains('-S'));
    // Not the bare 'cmake' (which the OE PATH would shadow) — the resolved host
    // path, so the SDK's old cmake is bypassed. Same exe builds too.
    expect(cfg.first, '/opt/host/cmake');
    expect(
      rec.calls.any(
        (c) => c.first == '/opt/host/cmake' && c.contains('--build'),
      ),
      isTrue,
    );
    // The toolchain file + OE env still flow through.
    expect(cfg, contains('-DCMAKE_TOOLCHAIN_FILE=/tc.cmake'));
    expect(rec.envs.first!['CC'], 'aarch64-none-linux-gnu-gcc');
  });

  test('hostTools: meson setup is invoked by the resolved host path', () async {
    final rec = recorder();
    final r =
        await CrossBuilder(
          _profile,
          runProcess: rec.run,
          hostTools: true,
          resolveHostTool: fakeHostTool,
        ).build(
          sourceDir: dir('src'),
          buildDir: dir('b'),
          generator: CrossGenerator.meson,
        );
    expect(r.success, isTrue);
    final setup = rec.calls.firstWhere((c) => c.contains('setup'));
    expect(setup.first, '/opt/host/meson');
    expect(setup, containsAll(['--cross-file', '/c.cross']));
  });

  test('hostTools: a missing host tool fails with a clear message', () async {
    final rec = recorder();
    final r =
        await CrossBuilder(
          _profile,
          runProcess: rec.run,
          hostTools: true,
          resolveHostTool: (_) => null,
        ).build(
          sourceDir: dir('src'),
          buildDir: dir('b'),
          generator: CrossGenerator.cmake,
        );
    expect(r.success, isFalse);
    expect(r.message, contains('no cmake found on the host PATH'));
  });

  test('a failed configure short-circuits the build', () async {
    final rec = recorder(failOn: (exe, args) => exe == 'cmake');
    final r = await CrossBuilder(_profile, runProcess: rec.run).build(
      sourceDir: dir('src'),
      buildDir: dir('b'),
      generator: CrossGenerator.cmake,
    );
    expect(r.success, isFalse);
    expect(r.message, contains('configure failed'));
    // configure failed → no --build step.
    expect(rec.calls.any((c) => c.contains('--build')), isFalse);
  });

  test('a failed ninja surfaces as a build failure', () async {
    final rec = recorder(failOn: (exe, args) => exe == 'ninja');
    final r = await CrossBuilder(_profile, runProcess: rec.run).build(
      sourceDir: dir('src'),
      buildDir: dir('b'),
      generator: CrossGenerator.meson,
    );
    expect(r.success, isFalse);
    expect(r.message, contains('ninja failed'));
  });

  test(
    'both modes blank host *FLAGS; only cross blanks the compiler',
    () async {
      final cross = recorder();
      await CrossBuilder(_profile, runProcess: cross.run).build(
        sourceDir: dir('s'),
        buildDir: dir('b'),
        generator: CrossGenerator.cmake,
      );
      // Cross: stray flags AND the compiler selection are blanked.
      expect(cross.envs.first!['CXXFLAGS'], '');
      expect(cross.envs.first!['CXX'], '');

      final native = recorder();
      await CrossBuilder(
        _profile,
        runProcess: native.run,
        neutralizeHostEnv: false,
      ).build(
        sourceDir: dir('s2'),
        buildDir: dir('b2'),
        generator: CrossGenerator.cmake,
      );
      // Native: stray flags blanked (no clang -stdlib leak), but the host
      // compiler choice passes through (CXX not forced empty).
      expect(native.envs.first!['CXXFLAGS'], '');
      expect(native.envs.first!.containsKey('CXX'), isFalse);
    },
  );

  test('cmake: appends raw cmakeArgs verbatim after the defines', () async {
    final rec = recorder();
    final r = await CrossBuilder(_profile, runProcess: rec.run).build(
      sourceDir: dir('src'),
      buildDir: dir('b'),
      generator: CrossGenerator.cmake,
      defines: {'FOO': 'BAR'},
      cmakeArgs: ['-Wno-dev', '--fresh'],
    );
    expect(r.success, isTrue);
    final cfg = rec.calls.firstWhere(
      (c) => c.first == 'cmake' && c.contains('-S'),
    );
    expect(cfg, containsAllInOrder(['-DFOO=BAR', '-Wno-dev', '--fresh']));
  });

  test('buildBackends builds each backend into its own dir', () async {
    final rec = recorder();
    final results = await CrossBuilder(_profile, runProcess: rec.run)
        .buildBackends(
          sourceDir: dir('src'),
          buildRoot: Workspace(tmp).root,
          generator: CrossGenerator.cmake,
          backends: {
            'wayland-egl': {'BUILD_BACKEND_WAYLAND_EGL': 'ON'},
            'drm-kms-egl': {'BUILD_BACKEND_DRM_GLES2': 'ON'},
          },
        );
    expect(results.map((r) => r.backend), ['wayland-egl', 'drm-kms-egl']);
    expect(results.every((r) => r.success), isTrue);
    final buildDirs = rec.calls
        .where((c) => c.contains('-B'))
        .map((c) => c[c.indexOf('-B') + 1])
        .toList();
    expect(buildDirs, [
      endsWith('build-wayland-egl'),
      endsWith('build-drm-kms-egl'),
    ]);
  });

  // End-to-end for the override channel: a --define override is baked into the
  // target's `defines`, and that same map is what the builder emits as `-D`.
  // These prove the overridden value actually reaches the configure argv — for
  // BOTH generators, since `defines` is generator-agnostic — and that the
  // manifest value it replaced is gone.
  group('withDefineOverrides reaches the configure argv', () {
    CrossTarget targetWith(String generator) => CrossTarget.fromMap({
      'provider': 'arm-gnu',
      'triple': 'aarch64-none-linux-gnu',
      'generator': generator,
      'defines': {'ENABLE_SENTRY': 'OFF', 'KEEP': '1'},
      'backends': {
        'wayland-egl': {
          'BUILD_BACKEND_WAYLAND_EGL': 'ON',
          'ENABLE_SENTRY': 'OFF',
        },
      },
    });

    test('cmake: the override wins and the manifest value is gone', () async {
      final rec = recorder();
      final t = targetWith(
        'cmake',
      ).withDefineOverrides(const {'ENABLE_SENTRY': 'ON'});
      final r = await CrossBuilder(_profile, runProcess: rec.run).build(
        sourceDir: dir('src'),
        buildDir: dir('b'),
        generator: t.generator,
        defines: t.defines,
      );
      expect(r.success, isTrue);
      final cfg = rec.calls.firstWhere(
        (c) => c.first == 'cmake' && c.contains('-S'),
      );
      expect(cfg, contains('-DENABLE_SENTRY=ON'));
      expect(cfg, isNot(contains('-DENABLE_SENTRY=OFF')));
      expect(cfg, contains('-DKEEP=1'));
    });

    test('meson: the same override reaches meson setup', () async {
      final rec = recorder();
      final t = targetWith(
        'meson',
      ).withDefineOverrides(const {'ENABLE_SENTRY': 'ON'});
      final r = await CrossBuilder(_profile, runProcess: rec.run).build(
        sourceDir: dir('src'),
        buildDir: dir('b'),
        generator: t.generator,
        defines: t.defines,
      );
      expect(r.success, isTrue);
      final setup = rec.calls.firstWhere((c) => c.first == 'meson');
      expect(setup, contains('-DENABLE_SENTRY=ON'));
      expect(setup, isNot(contains('-DENABLE_SENTRY=OFF')));
      expect(setup, contains('-DKEEP=1'));
    });

    test('cmake: an override reaches every backend configure', () async {
      final rec = recorder();
      final t = targetWith(
        'cmake',
      ).withDefineOverrides(const {'ENABLE_SENTRY': 'ON'});
      final results = await CrossBuilder(_profile, runProcess: rec.run)
          .buildBackends(
            sourceDir: dir('src'),
            buildRoot: Workspace(tmp).root,
            generator: t.generator,
            backends: {
              for (final e in t.backends.entries)
                e.key: {...t.defines, ...e.value},
            },
          );
      expect(results.single.success, isTrue);
      final cfg = rec.calls.firstWhere(
        (c) => c.first == 'cmake' && c.contains('-S'),
      );
      expect(cfg, contains('-DENABLE_SENTRY=ON'));
      expect(cfg, isNot(contains('-DENABLE_SENTRY=OFF')));
      expect(cfg, contains('-DBUILD_BACKEND_WAYLAND_EGL=ON'));
    });
  });
}
