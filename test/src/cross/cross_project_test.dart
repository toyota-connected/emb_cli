import 'dart:io';

import 'package:emb_cli/src/cross/cross_project.dart';
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
  });
}
