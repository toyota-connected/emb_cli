import 'dart:io';

import 'package:emb_cli/src/cross/cross_project.dart';
import 'package:emb_cli/src/cross/cross_target.dart';
import 'package:emb_cli/src/manifest/manifest_loader.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('deepMerge', () {
    test('nested maps merge key-by-key; scalars and lists replace', () {
      final base = {
        'provider': 'arm-gnu',
        'sysroot': {
          'partition': 2,
          'dev_packages': ['libdrm-dev', 'libgbm-dev'],
        },
        'defines': {'A': '1', 'B': '2'},
      };
      final over = {
        'triple': 'aarch64-linux-gnu',
        'sysroot': {
          'partition': 3,
          'dev_packages': ['libegl-dev'],
        },
        'defines': {'B': '9'},
      };
      final merged = deepMerge(base, over);
      expect(merged['provider'], 'arm-gnu'); // kept from base
      expect(merged['triple'], 'aarch64-linux-gnu'); // added
      final sysroot = merged['sysroot'] as Map;
      expect(sysroot['partition'], 3); // overridden
      // List replaced wholesale, not concatenated.
      expect(sysroot['dev_packages'], ['libegl-dev']);
      expect(merged['defines'], {'A': '1', 'B': '9'}); // nested map merged
    });

    test('does not mutate its inputs', () {
      final base = {
        'sysroot': {'partition': 2},
      };
      final over = {
        'sysroot': {'partition': 3},
      };
      deepMerge(base, over);
      expect((base['sysroot']! as Map)['partition'], 2);
    });
  });

  group('CrossProjectResolver', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('emb_proj_'));
    tearDown(() => tmp.deleteSync(recursive: true));

    group('applyAppLayer', () {
      late Directory appDir;
      setUp(() => appDir = Directory.systemTemp.createTempSync('emb_app_'));
      tearDown(() => appDir.deleteSync(recursive: true));

      void writeApp(String relPath, String body) {
        final f = File(p.join(appDir.path, relPath));
        f.parent.createSync(recursive: true);
        f.writeAsStringSync(body);
      }

      Map<String, dynamic> projectCross() => {
        'provider': 'arm-gnu',
        'triple': 'aarch64-none-linux-gnu',
        'sysroot': {
          'partition': 2,
          'dev_packages': ['libdrm-dev', 'libglib2.0-dev'],
        },
      };

      // The point of the layer: one app adds what only it needs, and the
      // board's own stack is kept rather than replaced.
      test('app dev_packages accumulate onto the project stack', () {
        writeApp('.emb/raspberry-pi.emb.yaml', '''
id: my-app
type: app
cross:
  targets:
    rpi5-trixie:
      sysroot:
        dev_packages:
          - libflatpak-dev
''');
        final merged = CrossProjectResolver().applyAppLayer(
          cross: projectCross(),
          appDir: appDir.path,
          targetName: 'rpi5-trixie',
        );
        final sysroot = merged['sysroot']! as Map;
        expect(sysroot['dev_packages'], [
          'libdrm-dev',
          'libglib2.0-dev',
          'libflatpak-dev',
        ]);
        expect(sysroot['partition'], 2, reason: 'project fields survive');
        expect(merged['provider'], 'arm-gnu');
      });

      test('an app scalar wins over the project', () {
        writeApp('.emb/raspberry-pi.emb.yaml', '''
id: my-app
cross:
  targets:
    rpi5-trixie:
      sysroot:
        snapshot: 2026-04-22
''');
        final merged = CrossProjectResolver().applyAppLayer(
          cross: projectCross(),
          appDir: appDir.path,
          targetName: 'rpi5-trixie',
        );
        expect((merged['sysroot']! as Map)['snapshot'], '2026-04-22');
      });

      test('a target the app does not name is untouched', () {
        writeApp('.emb/raspberry-pi.emb.yaml', '''
id: my-app
cross:
  targets:
    rpi4-trixie:
      sysroot: {dev_packages: [libflatpak-dev]}
''');
        final merged = CrossProjectResolver().applyAppLayer(
          cross: projectCross(),
          appDir: appDir.path,
          targetName: 'rpi5-trixie',
        );
        expect((merged['sysroot']! as Map)['dev_packages'], [
          'libdrm-dev',
          'libglib2.0-dev',
        ]);
      });

      test('an app with no manifest costs nothing', () {
        final merged = CrossProjectResolver().applyAppLayer(
          cross: projectCross(),
          appDir: appDir.path,
          targetName: 'rpi5-trixie',
        );
        expect(merged, projectCross());
      });

      // `local`/`host` are reserved target names, so an app cannot declare a
      // target for the native build; it states what that build needs in the
      // shared `cross:` block, symmetrically with the project side (where
      // selectTarget returns nativeCross for those names).
      test('native reads the app base block, not a named target', () {
        writeApp('.emb/base.emb.yaml', '''
id: my-app
cross:
  defines:
    DISABLE_PLUGINS: 'OFF'
  augment:
    - pkg: firebase-cpp-sdk
      min: "13.12.0"
      url: https://example.invalid/firebase.tar.gz
      build: cmake
''');
        final merged = CrossProjectResolver().applyAppLayer(
          cross: {'defines': <String, dynamic>{'DISABLE_PLUGINS': 'ON'}},
          appDir: appDir.path,
          targetName: 'local',
          native: true,
        );
        expect((merged['defines']! as Map)['DISABLE_PLUGINS'], 'OFF');
        expect((merged['augment']! as List).single, isA<Map<dynamic, dynamic>>()
            .having((m) => m['pkg'], 'pkg', 'firebase-cpp-sdk'));
      });

      test('a board target does not pick up the app base block', () {
        writeApp('.emb/base.emb.yaml', '''
id: my-app
cross:
  defines:
    DISABLE_PLUGINS: 'OFF'
''');
        final merged = CrossProjectResolver().applyAppLayer(
          cross: projectCross(),
          appDir: appDir.path,
          targetName: 'rpi5-trixie',
        );
        expect(merged['defines'], isNull);
      });

      test('native with no app base block costs nothing', () {
        final base = {'defines': <String, dynamic>{'DISABLE_PLUGINS': 'ON'}};
        final merged = CrossProjectResolver().applyAppLayer(
          cross: base,
          appDir: appDir.path,
          targetName: 'local',
          native: true,
        );
        expect(merged, base);
      });

      test('appLayerSourcePath resolves the base manifest for native', () {
        writeApp('.emb/base.emb.yaml', '''
id: my-app
cross:
  defines: {DISABLE_PLUGINS: 'OFF'}
''');
        final path = CrossProjectResolver().appLayerSourcePath(
          appDir: appDir.path,
          targetName: 'local',
          native: true,
        );
        expect(path, endsWith(p.join('.emb', 'base.emb.yaml')));
      });

      // An app layer is additive; a broken one must not take down a build
      // whose project manifest is fine.
      test('a malformed app manifest is ignored, not fatal', () {
        writeApp('.emb/raspberry-pi.emb.yaml', 'cross:\n  extends: no-such\n');
        final merged = CrossProjectResolver().applyAppLayer(
          cross: projectCross(),
          appDir: appDir.path,
          targetName: 'rpi5-trixie',
        );
        expect(merged, projectCross());
      });

      test('emb.yaml at the app root works as well as .emb/', () {
        writeApp('emb.yaml', '''
id: my-app
cross:
  targets:
    rpi5-trixie:
      sysroot: {dev_packages: [libflatpak-dev]}
''');
        final merged = CrossProjectResolver().applyAppLayer(
          cross: projectCross(),
          appDir: appDir.path,
          targetName: 'rpi5-trixie',
        );
        expect(
          (merged['sysroot']! as Map)['dev_packages'],
          contains('libflatpak-dev'),
        );
      });

      test('appLayerSourcePath names the file the layer came from', () {
        writeApp('.emb/raspberry-pi.emb.yaml', '''
id: my-app
cross:
  targets:
    rpi5-trixie:
      sysroot: {dev_packages: [libflatpak-dev]}
''');
        final src = CrossProjectResolver().appLayerSourcePath(
          appDir: appDir.path,
          targetName: 'rpi5-trixie',
        );
        expect(src, endsWith('raspberry-pi.emb.yaml'));
      });
    });

    File write(String relPath, String body) {
      final f = File(p.join(tmp.path, relPath));
      f.parent.createSync(recursive: true);
      f.writeAsStringSync(body);
      return f;
    }

    test('flat single file → one target named by platform.name', () {
      final f = write('pi5.emb.yaml', '''
id: ivi-homescreen
platform:
  name: pi5
  description: Raspberry Pi 5
cross:
  provider: arm-gnu
  triple: aarch64-linux-gnu
  backends:
    wayland-egl: {BUILD_BACKEND_WAYLAND_EGL: 'ON'}
''');
      final project = CrossProjectResolver().resolve(f.path)!;
      expect(project.targets.keys, ['pi5']);
      final ref = project.targets['pi5']!;
      expect(ref.cross['provider'], 'arm-gnu');
      expect(ref.cross.containsKey('targets'), isFalse);
      expect(ref.platform['description'], 'Raspberry Pi 5');
      expect(ref.family, isNull);
      expect(project.nativeCross['provider'], 'arm-gnu');
    });

    test('cross.targets file → one target per variant, sharing the base', () {
      final f = write('rpi.emb.yaml', '''
id: rpi-family
platform: {name: raspberry-pi}
cross:
  provider: arm-gnu
  triple: aarch64-linux-gnu
  sysroot: {partition: 2}
  targets:
    rpi4: {cpu_flags: -mcpu=cortex-a72}
    rpi5: {cpu_flags: -mcpu=cortex-a76}
''');
      final project = CrossProjectResolver().resolve(f.path)!;
      expect(project.targets.keys, ['rpi4', 'rpi5']);
      final rpi5 = project.targets['rpi5']!;
      expect(rpi5.cross['provider'], 'arm-gnu'); // shared field
      expect(rpi5.cross['cpu_flags'], '-mcpu=cortex-a76'); // variant override
      expect((rpi5.cross['sysroot'] as Map)['partition'], 2); // shared sysroot
      expect(rpi5.cross.containsKey('targets'), isFalse);
      expect(rpi5.family, 'raspberry-pi'); // grouped under the family
    });

    test('shared cross.augment unions into a target that declares its own', () {
      final f = write('proj.emb.yaml', '''
id: ivi
cross:
  provider: arm-gnu
  triple: aarch64-linux-gnu
  augment:
    - pkg: sentry-native
      min: '0.15.3'
      url: s.zip
      build: cmake
      requires_define: BUILD_CRASH_HANDLER
  targets:
    rpi5:
      cpu_flags: -mcpu=cortex-a76
      augment:
        - {pkg: libdisplay-info, min: '0.2.0', url: di.tar.gz, build: meson}
''');
      final rpi5 = CrossProjectResolver().resolve(f.path)!.targets['rpi5']!;
      // shared [sentry-native] ∪ target [libdisplay-info], base first.
      expect((rpi5.cross['augment'] as List).map((e) => (e as Map)['pkg']), [
        'sentry-native',
        'libdisplay-info',
      ]);
    });

    test('.emb/ dir unions flat + family files over a shared base', () {
      write('proj/.emb/base.emb.yaml', '''
id: shared
cross:
  provider: arm-gnu
  sysroot:
    partition: 2
    dev_packages: [libdrm-dev]
  defines: {DISABLE_PLUGINS: 'ON'}
''');
      write('proj/.emb/imx93.emb.yaml', '''
platform: {name: imx93-evk}
cross:
  provider: yocto-recipe
  triple: aarch64-poky-linux
''');
      write('proj/.emb/rpi.emb.yaml', '''
platform: {name: raspberry-pi}
cross:
  triple: aarch64-linux-gnu
  targets:
    rpi4: {cpu_flags: -mcpu=cortex-a72}
    rpi5: {cpu_flags: -mcpu=cortex-a76}
''');
      final project = CrossProjectResolver().resolve(p.join(tmp.path, 'proj'))!;
      // imx93 (flat) + rpi4/rpi5 (family) — sorted by file: imx93 then rpi.
      expect(project.targets.keys, ['imx93-evk', 'rpi4', 'rpi5']);

      // Flat file overrides the base provider but inherits base sysroot/defines.
      final imx = project.targets['imx93-evk']!;
      expect(imx.cross['provider'], 'yocto-recipe');
      expect((imx.cross['sysroot'] as Map)['partition'], 2);
      expect((imx.cross['defines'] as Map)['DISABLE_PLUGINS'], 'ON');
      expect(imx.family, isNull);

      // Family variant inherits the base provider it never overrides.
      final rpi5 = project.targets['rpi5']!;
      expect(rpi5.cross['provider'], 'arm-gnu');
      expect(rpi5.cross['cpu_flags'], '-mcpu=cortex-a76');
      // The family file declared no sysroot, so the base's survives.
      expect((rpi5.cross['sysroot'] as Map)['dev_packages'], ['libdrm-dev']);
      expect(rpi5.family, 'raspberry-pi');

      // Native build uses the base block.
      expect(project.nativeCross['provider'], 'arm-gnu');
    });

    test('a board backends set replaces the base, it does not union', () {
      write('proj/.emb/base.emb.yaml', '''
id: shared
cross:
  provider: arm-gnu
  backends: {wayland-egl: {BUILD_BACKEND_WAYLAND_EGL: 'ON'}}
''');
      write('proj/.emb/imx93.emb.yaml', '''
platform: {name: imx93-evk}
cross:
  provider: yocto-recipe
  triple: aarch64-poky-linux
  backends: {drm-kms-egl: {BUILD_BACKEND_DRM_KMS_EGL: 'ON'}}
''');
      final project = CrossProjectResolver().resolve(p.join(tmp.path, 'proj'))!;
      final imx = project.targets['imx93-evk']!;
      // Only the board's backend — not the inherited wayland-egl default.
      expect((imx.cross['backends'] as Map).keys, ['drm-kms-egl']);
      expect(imx.arch, 'aarch64'); // from the triple
    });

    test('arch falls back to supported_archs when there is no triple', () {
      final f = write('pi.emb.yaml', '''
id: pi
supported_archs: [arm64]
platform: {name: pi5}
cross: {provider: arm-gnu, image_url: https://x/y.img.xz}
''');
      final ref = CrossProjectResolver().resolve(f.path)!.targets['pi5']!;
      expect(ref.arch, 'arm64');
    });

    test('duplicate target names across files throw', () {
      write('proj/.emb/a.emb.yaml', '''
platform: {name: board}
cross: {provider: arm-gnu, triple: aarch64-linux-gnu}
''');
      write('proj/.emb/b.emb.yaml', '''
platform: {name: board}
cross: {provider: yocto-recipe, triple: aarch64-poky-linux}
''');
      expect(
        () => CrossProjectResolver().resolve(p.join(tmp.path, 'proj')),
        throwsA(isA<CrossProjectException>()),
      );
    });

    test('a target named local/host is rejected as reserved', () {
      final f = write('bad.emb.yaml', '''
id: bad
cross:
  provider: arm-gnu
  targets:
    local: {cpu_flags: -mcpu=native}
''');
      expect(
        () => CrossProjectResolver().resolve(f.path),
        throwsA(isA<CrossProjectException>()),
      );
    });

    test('resolve returns null when no manifest is present', () {
      expect(CrossProjectResolver().resolve(tmp.path), isNull);
    });
  });

  group('CrossProjectResolver extends (board layer)', () {
    late Directory tmp;
    late Directory boards;
    setUp(() {
      tmp = Directory.systemTemp.createTempSync('emb_ext_');
      boards = Directory(p.join(tmp.path, 'boards'))..createSync();
      File(p.join(boards.path, 'raspberry-pi.emb.yaml')).writeAsStringSync('''
id: raspberry-pi
type: board
cross:
  provider: arm-gnu
  triple: aarch64-none-linux-gnu
  sysroot:
    partition: 2
    dev_packages: [libegl-dev, libwayland-dev, libdrm-dev]
  targets:
    rpi5-bookworm:
      toolchain_version: 12.3.rel1
      image_url: https://example/bookworm.img.xz
      cpu_flags: [-mcpu=cortex-a76]
    rpi5-trixie:
      toolchain_version: 15.2.rel1
      image_url: https://example/trixie.img.xz
      cpu_flags: [-mcpu=cortex-a76]
      augment:
        - {pkg: libdisplay-info, min: '0.2.0', url: di.tar.gz, build: meson}
''');
    });
    tearDown(() => tmp.deleteSync(recursive: true));

    CrossProject resolveProject(String body) {
      final f = File(p.join(tmp.path, 'proj.emb.yaml'))
        ..writeAsStringSync(body);
      return CrossProjectResolver(
        const ManifestLoader(),
        boards,
      ).resolve(f.path)!;
    }

    test('inherits the board hardware and overlays project backends', () {
      final project = resolveProject('''
id: ivi-homescreen
cross:
  targets:
    rpi5-bookworm:
      extends: rpi5-bookworm
      backends:
        drm-kms-vulkan: {BUILD_BACKEND_DRM_KMS_VULKAN: 'ON'}
''');
      final cross = project.targets['rpi5-bookworm']!.cross;
      // Hardware from the board:
      expect(cross['provider'], 'arm-gnu');
      expect(cross['triple'], 'aarch64-none-linux-gnu');
      expect(cross['toolchain_version'], '12.3.rel1');
      expect(cross['cpu_flags'], ['-mcpu=cortex-a76']);
      // Project layer present, and the `extends` key is consumed.
      expect((cross['backends'] as Map).keys, ['drm-kms-vulkan']);
      expect(cross.containsKey('extends'), isFalse);
    });

    test('dev_packages union (board base + project additions, deduped)', () {
      final project = resolveProject('''
id: ivi-homescreen
cross:
  targets:
    rpi5-trixie:
      extends: rpi5-trixie
      sysroot:
        dev_packages: [libwayland-dev, libgstreamer1.0-dev, libsecret-1-dev]
''');
      final sysroot = project.targets['rpi5-trixie']!.cross['sysroot'] as Map;
      expect(sysroot['partition'], 2); // from the board
      // base [egl, wayland, drm] ∪ project [wayland(dup), gst, secret]
      expect(sysroot['dev_packages'], [
        'libegl-dev',
        'libwayland-dev',
        'libdrm-dev',
        'libgstreamer1.0-dev',
        'libsecret-1-dev',
      ]);
    });

    test('augment union (base + derived additions, order-preserving)', () {
      final project = resolveProject('''
id: ivi-homescreen
cross:
  targets:
    rpi5-trixie:
      extends: rpi5-trixie
      augment:
        - pkg: sentry-native
          min: '0.15.3'
          url: sentry.zip
          build: cmake
          requires_define: BUILD_CRASH_HANDLER
''');
      final augment = project.targets['rpi5-trixie']!.cross['augment'] as List;
      // board [libdisplay-info] ∪ project [sentry-native]
      expect(augment.map((e) => (e as Map)['pkg']), [
        'libdisplay-info',
        'sentry-native',
      ]);
    });

    test('a derived augment for the same pkg replaces the inherited one', () {
      final project = resolveProject('''
id: ivi-homescreen
cross:
  targets:
    rpi5-trixie:
      extends: rpi5-trixie
      augment:
        - {pkg: libdisplay-info, min: '0.3.0', url: newer.tar.gz, build: meson}
''');
      final augment = project.targets['rpi5-trixie']!.cross['augment'] as List;
      expect(augment.length, 1);
      expect((augment.single as Map)['min'], '0.3.0'); // derived wins
    });

    test('backends replace (not union) across the layer', () {
      final project = resolveProject('''
id: ivi-homescreen
cross:
  targets:
    rpi5-bookworm:
      extends: rpi5-bookworm
      backends:
        software: {BUILD_BACKEND_SOFTWARE: 'ON'}
''');
      // The board has no backends; the project's set stands alone.
      final backends =
          project.targets['rpi5-bookworm']!.cross['backends'] as Map;
      expect(backends.keys, ['software']);
    });

    test('modules pass through the layer and parse into ModuleSpec', () {
      final project = resolveProject('''
id: ivi-homescreen
cross:
  targets:
    rpi5-bookworm:
      extends: rpi5-bookworm
      modules:
        - name: hello
          path: native/hello
          build: cmake
          artifacts: [libhello.so]
''');
      final target = project.targets['rpi5-bookworm']!;
      final cross = CrossTarget.fromMap(target.cross);
      expect(cross.modules, hasLength(1));
      expect(cross.modules.single.name, 'hello');
      expect(cross.modules.single.build, ModuleBuild.cmake);
      expect(cross.modules.single.artifacts, ['libhello.so']);
    });

    test('a re-declared modules list replaces (not unions) across layers', () {
      // project layer: one module.
      Directory(p.join(tmp.path, 'proj', '.emb')).createSync(recursive: true);
      File(p.join(tmp.path, 'proj', '.emb', 'rpi.emb.yaml')).writeAsStringSync(
        '''
id: ivi-homescreen
cross:
  targets:
    rpi5-bookworm:
      extends: rpi5-bookworm
      modules:
        - {name: base, path: native/base, artifacts: [libbase.so]}
''',
      );
      // app layer: a different module set — replaces the project's.
      final app = File(p.join(tmp.path, 'app.emb.yaml'))
        ..writeAsStringSync('''
id: myapp
cross:
  targets:
    rpi5-bookworm:
      extends: 'proj#rpi5-bookworm'
      modules:
        - {name: app, path: native/app, artifacts: [libapp_native.so]}
''');
      final project = CrossProjectResolver(
        const ManifestLoader(),
        boards,
      ).resolve(app.path)!;
      final cross = CrossTarget.fromMap(
        project.targets['rpi5-bookworm']!.cross,
      );
      expect(cross.modules.map((m) => m.name), ['app']);
    });

    test('unknown board name throws', () {
      expect(
        () => resolveProject('''
id: ivi-homescreen
cross:
  targets:
    x: {extends: no-such-board}
'''),
        throwsA(isA<CrossProjectException>()),
      );
    });

    test('app extends a project target which extends a board (3 layers)', () {
      // project: tmp/proj/.emb/rpi.emb.yaml — extends the board, adds backends.
      Directory(p.join(tmp.path, 'proj', '.emb')).createSync(recursive: true);
      File(p.join(tmp.path, 'proj', '.emb', 'rpi.emb.yaml')).writeAsStringSync(
        '''
id: ivi-homescreen
cross:
  targets:
    rpi5-bookworm:
      extends: rpi5-bookworm
      backends:
        drm-kms-egl: {BUILD_BACKEND_DRM_KMS_EGL: 'ON'}
      sysroot:
        dev_packages: [libproject-dev]
''',
      );
      // app: a flat manifest extending the project target, adding plugins.
      final app = File(p.join(tmp.path, 'app.emb.yaml'))
        ..writeAsStringSync('''
id: myapp
cross:
  targets:
    rpi5-bookworm:
      extends: 'proj#rpi5-bookworm'
      defines: {DISABLE_PLUGINS: 'OFF'}
      sysroot:
        dev_packages: [libapp-dev]
''');
      final project = CrossProjectResolver(
        const ManifestLoader(),
        boards,
      ).resolve(app.path)!;
      final cross = project.targets['rpi5-bookworm']!.cross;
      // hardware from the board layer:
      expect(cross['toolchain_version'], '12.3.rel1');
      expect(cross['cpu_flags'], ['-mcpu=cortex-a76']);
      // backends from the project layer:
      expect((cross['backends'] as Map).keys, ['drm-kms-egl']);
      // plugin defines from the app layer:
      expect((cross['defines'] as Map)['DISABLE_PLUGINS'], 'OFF');
      // dev_packages union across all three layers:
      expect(
        (cross['sysroot'] as Map)['dev_packages'],
        containsAll(['libegl-dev', 'libproject-dev', 'libapp-dev']),
      );
      expect(cross.containsKey('extends'), isFalse);
    });

    test('extends an unknown project target throws', () {
      Directory(p.join(tmp.path, 'proj', '.emb')).createSync(recursive: true);
      File(p.join(tmp.path, 'proj', '.emb', 'rpi.emb.yaml')).writeAsStringSync(
        '''
id: ivi-homescreen
cross:
  targets:
    rpi5-bookworm: {extends: rpi5-bookworm}
''',
      );
      final app = File(p.join(tmp.path, 'app.emb.yaml'))
        ..writeAsStringSync('''
id: myapp
cross:
  targets:
    x: {extends: 'proj#no-such-target'}
''');
      expect(
        () => CrossProjectResolver(
          const ManifestLoader(),
          boards,
        ).resolve(app.path),
        throwsA(isA<CrossProjectException>()),
      );
    });

    test('extends a missing project dir throws', () {
      final app = File(p.join(tmp.path, 'app.emb.yaml'))
        ..writeAsStringSync('''
id: myapp
cross:
  targets:
    x: {extends: 'no-such-proj#rpi5-bookworm'}
''');
      expect(
        () => CrossProjectResolver(
          const ManifestLoader(),
          boards,
        ).resolve(app.path),
        throwsA(isA<CrossProjectException>()),
      );
    });
  });

  // The bug this layer exists to fix: an AOT-compiled `emb` carries no package
  // data files, so package_config and the script walk both miss and the
  // registry comes back empty. The installed data dir is the rung that makes
  // `extends:` work off a checkout.
  group('CrossProjectResolver board library discovery', () {
    late Directory tmp;

    setUp(() => tmp = Directory.systemTemp.createTempSync('emb_boardsdir_'));
    tearDown(() => tmp.deleteSync(recursive: true));

    /// A data home containing one board, laid out as an install would write it.
    Directory installedBoards() {
      final d = Directory(p.join(tmp.path, 'data', 'emb', 'boards'))
        ..createSync(recursive: true);
      File(p.join(d.path, 'raspberry-pi.emb.yaml')).writeAsStringSync('''
id: raspberry-pi
type: board
cross:
  provider: arm-gnu
  triple: aarch64-none-linux-gnu
  targets:
    rpi5-trixie:
      toolchain_version: 15.2.rel1
''');
      return d;
    }

    File appExtending(String board) =>
        File(p.join(tmp.path, 'app.emb.yaml'))..writeAsStringSync('''
id: myapp
cross:
  targets:
    x: {extends: $board}
''');

    test('rung 3: resolves from the installed data dir', () {
      installedBoards();
      final project = CrossProjectResolver(const ManifestLoader(), null, {
        'HOME': tmp.path,
        'XDG_DATA_HOME': p.join(tmp.path, 'data'),
      }).resolve(appExtending('rpi5-trixie').path)!;
      expect(project.targets['x']!.cross['triple'], 'aarch64-none-linux-gnu');
    });

    test('EMB_BOARDS_DIR outranks the installed data dir', () {
      installedBoards();
      final other = Directory(p.join(tmp.path, 'other'))..createSync();
      File(p.join(other.path, 'b.emb.yaml')).writeAsStringSync('''
id: other
type: board
cross:
  provider: arm-gnu
  triple: OVERRIDE-TRIPLE
  targets:
    rpi5-trixie: {}
''');
      final project = CrossProjectResolver(const ManifestLoader(), null, {
        'HOME': tmp.path,
        'XDG_DATA_HOME': p.join(tmp.path, 'data'),
        'EMB_BOARDS_DIR': other.path,
      }).resolve(appExtending('rpi5-trixie').path)!;
      expect(project.targets['x']!.cross['triple'], 'OVERRIDE-TRIPLE');
    });

    test('an empty registry says the library is missing, not the name', () {
      // Regression guard for the reported bug: `Known boards: none.` reads as a
      // typo'd board name and sends people to audit a manifest that is fine.
      //
      // Driven through the override rung: under `dart test` package_config is
      // set, so rung 4 finds the checkout's own boards/ and the registry is
      // never genuinely empty here. Pointing at an empty directory reproduces
      // the state an installed emb is in without faking the resolver.
      final empty = Directory(p.join(tmp.path, 'empty'))..createSync();
      expect(
        () => CrossProjectResolver(
          const ManifestLoader(),
          empty,
        ).resolve(appExtending('rpi5-trixie').path),
        throwsA(
          isA<CrossProjectException>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('board library not found'),
              contains('Looked in:'),
              contains('emb boards sync'),
              isNot(contains('unknown board')),
            ),
          ),
        ),
      );
    });

    test('a real miss against a loaded library still names the board', () {
      installedBoards();
      expect(
        () => CrossProjectResolver(const ManifestLoader(), null, {
          'HOME': tmp.path,
          'XDG_DATA_HOME': p.join(tmp.path, 'data'),
        }).resolve(appExtending('no-such-board').path),
        throwsA(
          isA<CrossProjectException>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('unknown board "no-such-board"'),
              contains('rpi5-trixie'),
              isNot(contains('not found')),
            ),
          ),
        ),
      );
    });
  });

  group('selectTarget', () {
    CrossProject project({String? defaultTarget}) => CrossProject(
      id: 'proj',
      defaultTarget: defaultTarget,
      nativeCross: const {'provider': 'arm-gnu'},
      targets: {
        'pi5': CrossTargetRef(
          name: 'pi5',
          cross: const {'provider': 'arm-gnu', 'image_url': 'x'},
          platform: const {},
        ),
      },
    );

    test('an explicit named target selects its cross map', () {
      final s = project().selectTarget('pi5')!;
      expect(s.name, 'pi5');
      expect(s.isNative, isFalse);
      expect(s.cross['image_url'], 'x');
    });

    test('omitting --target uses the manifest default', () {
      final s = project(defaultTarget: 'pi5').selectTarget(null)!;
      expect(s.name, 'pi5');
      expect(s.isNative, isFalse);
    });

    test('local/host select the native build', () {
      for (final t in ['local', 'host']) {
        final s = project().selectTarget(t)!;
        expect(s.isNative, isTrue);
        expect(s.cross, project().nativeCross);
      }
    });

    test('local carries the native manifest path so its patches resolve', () {
      final s = CrossProject(
        id: 'proj',
        nativeCross: const {'provider': 'arm-gnu'},
        nativeSourcePath: '/work/.emb/base.emb.yaml',
        targets: const {},
      ).selectTarget('local')!;
      expect(s.isNative, isTrue);
      expect(s.sourcePath, '/work/.emb/base.emb.yaml');
    });

    test('local sourcePath is null when nativeCross has no backing file', () {
      // e.g. an `.emb/` dir without a base manifest.
      final s = project().selectTarget('local')!;
      expect(s.sourcePath, isNull);
    });

    test('no default and no --target falls back to native local', () {
      final s = project().selectTarget(null)!;
      expect(s.name, 'local');
      expect(s.isNative, isTrue);
    });

    test('an unknown named target returns null', () {
      expect(project().selectTarget('nope'), isNull);
    });
  });
}
