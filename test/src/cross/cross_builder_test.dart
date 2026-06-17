import 'dart:io';

import 'package:emb_cli/src/cross/cross_builder.dart';
import 'package:emb_cli/src/cross/cross_profile.dart';
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
({
  Future<ProcessResult> Function(
    String,
    List<String>, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool includeParentEnvironment,
    bool runInShell,
  })
  run,
  List<List<String>> calls,
  List<Map<String, String>?> envs,
})
recorder({bool Function(String exe, List<String> args)? failOn}) {
  final calls = <List<String>>[];
  final envs = <Map<String, String>?>[];
  Future<ProcessResult> run(
    String exe,
    List<String> args, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool includeParentEnvironment = true,
    bool runInShell = false,
  }) async {
    calls.add([exe, ...args]);
    envs.add(environment);
    final fail = failOn?.call(exe, args) ?? false;
    return ProcessResult(0, fail ? 1 : 0, '', 'boom');
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
}
