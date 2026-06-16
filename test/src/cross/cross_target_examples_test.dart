import 'dart:io';

import 'package:emb_cli/src/cross/cross_profile.dart';
import 'package:emb_cli/src/cross/cross_target.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

/// Load the `cross:` block of an example manifest and parse it into a
/// [CrossTarget]. YAML nodes are deep-converted to plain Dart collections so
/// `as` casts and `whereType` behave as in production (where the manifest
/// loader hands plain maps).
CrossTarget _loadCross(String filename) {
  final file = File(p.join('examples', 'cross', filename));
  expect(file.existsSync(), isTrue, reason: 'missing example: ${file.path}');
  final doc =
      _plain(loadYaml(file.readAsStringSync()))! as Map<dynamic, dynamic>;
  final cross = doc['cross'] as Map<dynamic, dynamic>?;
  expect(cross, isNotNull, reason: '$filename has no cross: block');
  return CrossTarget.fromMap(cross!);
}

Object? _plain(Object? node) {
  if (node is YamlMap) {
    return node.map((k, v) => MapEntry(_plain(k), _plain(v)));
  }
  if (node is YamlList) {
    return node.map(_plain).toList();
  }
  return node;
}

void main() {
  group('example cross manifests', () {
    const all = [
      'pi5.emb.yaml',
      'unoq.emb.yaml',
      'radxa_zero3.emb.yaml',
      'beagleplay.emb.yaml',
      'nitrogen8mm.emb.yaml',
      'agl_sdk_local.emb.yaml',
      'agl_sdk_url.emb.yaml',
    ];

    test('every manifest parses with a known provider', () {
      for (final f in all) {
        final t = _loadCross(f);
        expect(
          CrossProviderKind.values,
          contains(t.provider),
          reason: '$f produced an unknown provider',
        );
      }
    });

    test('pi5 — arm-gnu, pinned bookworm, cortex-a76, image sysroot', () {
      final t = _loadCross('pi5.emb.yaml');
      expect(t.provider, CrossProviderKind.armGnu);
      expect(t.triple, 'aarch64-none-linux-gnu');
      expect(t.versionPolicy, ToolchainVersionPolicy.pinned);
      expect(t.toolchainVersion, '12.3.rel1');
      expect(t.sysroot?.source, SysrootProvenance.image);
      expect(t.imageUrl, contains('raspios-bookworm'));
      expect(t.cpuFlags, ['-mcpu=cortex-a76']);
      expect(t.augment, hasLength(2));
      expect(t.augment[0].pkg, 'libdisplay-info');
      expect(t.augment[0].build, CrossGenerator.meson);
      expect(t.augment[0].staticLink, isTrue);
      expect(t.augment[1].pkg, 'vulkan-headers');
      expect(t.augment[1].build, CrossGenerator.cmake);
      expect(t.augment[1].staticLink, isFalse);
    });

    test('unoq — arm-gnu, derive, DEVICE sysroot (rsync)', () {
      final t = _loadCross('unoq.emb.yaml');
      expect(t.provider, CrossProviderKind.armGnu);
      expect(t.versionPolicy, ToolchainVersionPolicy.deriveFromSysroot);
      expect(t.toolchainVersion, isNull);
      expect(t.cpuFlags, ['-mcpu=cortex-a53']);
      // Sysroot comes from a live device, not an image.
      expect(t.sysroot?.source, SysrootProvenance.device);
      expect(t.sysroot?.deviceHost, 'ubuntu@unoq.local');
      expect(t.sysroot?.sshPort, 22);
      expect(t.imageUrl, isNull);
      expect(t.augment, hasLength(1));
    });

    test('radxa_zero3 — arm-gnu, pinned bookworm, cortex-a55, image', () {
      final t = _loadCross('radxa_zero3.emb.yaml');
      expect(t.provider, CrossProviderKind.armGnu);
      expect(t.versionPolicy, ToolchainVersionPolicy.pinned);
      expect(t.toolchainVersion, '12.3.rel1');
      expect(t.sysroot?.source, SysrootProvenance.image);
      expect(t.imageUrl, contains('radxa-zero3'));
      expect(t.cpuFlags, ['-mcpu=cortex-a55']);
      expect(t.augment, hasLength(2));
    });

    test('beagleplay — arm-gnu, pinned trixie, cortex-a53, no augment', () {
      final t = _loadCross('beagleplay.emb.yaml');
      expect(t.provider, CrossProviderKind.armGnu);
      expect(t.versionPolicy, ToolchainVersionPolicy.pinned);
      expect(t.toolchainVersion, '15.2.rel1');
      expect(t.sysroot?.source, SysrootProvenance.image);
      expect(t.imageUrl, contains('beagleplay-debian-13.5'));
      expect(t.cpuFlags, ['-mcpu=cortex-a53']);
      expect(t.augment, isEmpty);
    });

    test('nitrogen8mm — yocto-recipe, weston, OE march flags', () {
      final t = _loadCross('nitrogen8mm.emb.yaml');
      expect(t.provider, CrossProviderKind.yoctoRecipe);
      expect(t.triple, 'aarch64-poky-linux');
      expect(t.yoctoBuild, '/opt/yocto/imx8mm/build');
      expect(t.machineTuple, 'armv8a-mx8mm-poky-linux');
      expect(t.recipe, 'weston');
      expect(t.cpuFlags, [
        '-march=armv8-a+crc+crypto',
        '-mbranch-protection=standard',
      ]);
      expect(t.sysroot, isNull); // Yocto sysroot is intrinsic, not arm-gnu
      expect(t.augment, hasLength(1));
      expect(t.augment.single.pkg, 'libdisplay-info');
    });

    test('AGL SDK LOCAL — sdk_path, agl-linux triple, no url', () {
      final t = _loadCross('agl_sdk_local.emb.yaml');
      expect(t.provider, CrossProviderKind.yoctoSdk);
      expect(t.sdkPath, '/opt/agl-sdk/13.0.0-aarch64');
      expect(t.sdkUrl, isNull);
      expect(t.sdkEnvSetup, isNull);
      expect(t.triple, 'aarch64-agl-linux');
      expect(t.augment, isEmpty);
    });

    test('AGL SDK URL — download.automotivelinux.org installer, no path', () {
      final t = _loadCross('agl_sdk_url.emb.yaml');
      expect(t.provider, CrossProviderKind.yoctoSdk);
      expect(t.sdkPath, isNull);
      expect(t.sdkUrl, startsWith('https://download.automotivelinux.org/AGL/'));
      expect(
        t.sdkUrl,
        endsWith(
          'poky-agl-glibc-x86_64-agl-demo-platform-crosssdk-'
          'aarch64-raspberrypi4-64-toolchain-10.93.1.sh',
        ),
      );
      expect(t.triple, 'aarch64-agl-linux');
    });

    test('unknown provider token throws ArgumentError', () {
      expect(
        () => CrossTarget.fromMap(const {'provider': 'nonsense'}),
        throwsArgumentError,
      );
    });

    test('bare top-level image_url folds into an image sysroot spec', () {
      final t = CrossTarget.fromMap(const {
        'provider': 'arm-gnu',
        'image_url': 'https://example/x.img.xz',
      });
      expect(t.sysroot?.source, SysrootProvenance.image);
      expect(t.imageUrl, 'https://example/x.img.xz');
    });

    test('rootfs partition defaults to 2 and is overridable (#6)', () {
      final def = CrossTarget.fromMap(const {
        'provider': 'arm-gnu',
        'image_url': 'https://example/x.img.xz',
      });
      expect(def.sysroot?.partition, 2);
      final ovr = CrossTarget.fromMap(const {
        'provider': 'arm-gnu',
        'sysroot': {
          'source': 'image',
          'image_url': 'https://example/x.img.xz',
          'partition': 3,
        },
      });
      expect(ovr.sysroot?.partition, 3);
    });

    test('parses the backends matrix + generator (defaults to cmake)', () {
      final t = CrossTarget.fromMap(const {
        'provider': 'arm-gnu',
        'backends': {
          'wayland-egl': {'BUILD_BACKEND_WAYLAND_EGL': 'ON'},
          'drm-kms-egl': {'BUILD_BACKEND_DRM_GLES2': 'ON'},
        },
      });
      expect(t.generator, CrossGenerator.cmake);
      expect(t.backends.keys, ['wayland-egl', 'drm-kms-egl']);
      expect(t.backends['wayland-egl'], {'BUILD_BACKEND_WAYLAND_EGL': 'ON'});
    });
  });
}
