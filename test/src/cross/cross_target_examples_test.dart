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

    test('pi5 — arm-gnu, pinned bookworm, cortex-a76, validated build+deb', () {
      final t = _loadCross('pi5.emb.yaml');
      expect(t.provider, CrossProviderKind.armGnu);
      expect(t.triple, 'aarch64-none-linux-gnu');
      expect(t.versionPolicy, ToolchainVersionPolicy.pinned);
      expect(t.toolchainVersion, '12.3.rel1');
      expect(t.sysroot?.source, SysrootProvenance.image);
      expect(t.imageUrl, contains('raspios-bookworm'));
      expect(t.cpuFlags, ['-mcpu=cortex-a76']);
      // The validated config builds the drm-kms-egl backend with a single
      // source-built augment (libdisplay-info 0.2.0) and packages a .deb.
      expect(t.augment.single.pkg, 'libdisplay-info');
      expect(t.augment.single.build, CrossGenerator.meson);
      expect(t.augment.single.staticLink, isTrue);
      expect(t.augment.single.host, isFalse); // target lib, not a host tool
      expect(t.sysroot?.devPackages, contains('libdrm-dev'));
      expect(t.sysroot?.devPackages, contains('libegl-dev'));
      expect(t.backends.keys, ['drm-kms-egl']);
      expect(t.backends['drm-kms-egl']!['BUILD_BACKEND_DRM_KMS_EGL'], 'ON');
      expect(t.package?.name, 'ivi-homescreen');
      expect(t.package?.bin, 'shell/homescreen');
      expect(t.package?.installDir, '/usr/bin');
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

    test('radxa_zero3 — arm-gnu, p3 rootfs, drm symlink, 3 backends', () {
      final t = _loadCross('radxa_zero3.emb.yaml');
      expect(t.provider, CrossProviderKind.armGnu);
      expect(t.versionPolicy, ToolchainVersionPolicy.pinned);
      expect(t.toolchainVersion, '12.3.rel1');
      expect(t.sysroot?.source, SysrootProvenance.image);
      expect(t.imageUrl, contains('radxa-zero3'));
      expect(t.cpuFlags, ['-mcpu=cortex-a55']);
      expect(
        t.augment,
        hasLength(1),
      ); // libdisplay-info (vulkan-headers dropped)
      // Image quirks: rootfs on p3, and a drm->libdrm sysroot symlink because
      // radxa's linux-libc-dev omits /usr/include/drm/.
      expect(t.sysroot?.partition, 3);
      expect(t.sysroot?.devPackages, contains('linux-libc-dev'));
      expect(t.sysroot?.symlinks, {'usr/include/drm': 'libdrm'});
      // The three backends supported on the board.
      expect(t.backends.keys, ['wayland-egl', 'drm-kms-egl', 'software']);
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

    test('AGL SDK LOCAL — buildable wayland-egl + agl-shell', () {
      final t = _loadCross('agl_sdk_local.emb.yaml');
      expect(t.provider, CrossProviderKind.yoctoSdk);
      expect(t.sdkPath, '/opt/agl-sdk/13.0.0-aarch64');
      expect(t.sdkUrl, isNull);
      expect(t.sdkEnvSetup, isNull);
      expect(t.triple, 'aarch64-agl-linux');
      expect(t.augment, isEmpty);
      // Buildable, like agl_sdk_url: host cmake + wayland-egl + agl-shell.
      expect(t.hostTools, isTrue);
      expect(t.backends.keys, ['wayland-egl']);
      expect(t.backends['wayland-egl']!['BUILD_BACKEND_WAYLAND_EGL'], 'ON');
      expect(t.backends['wayland-egl']!['ENABLE_AGL_SHELL_CLIENT'], 'ON');
      expect(t.package?.bin, 'shell/homescreen');
    });

    test('AGL SDK URL — buildable wayland-egl + agl-shell via host cmake', () {
      final t = _loadCross('agl_sdk_url.emb.yaml');
      expect(t.provider, CrossProviderKind.yoctoSdk);
      expect(t.sdkPath, isNull);
      expect(t.sdkUrl, startsWith('https://archive.automotivelinux.org/'));
      expect(
        t.sdkUrl,
        endsWith(
          'poky-agl-glibc-x86_64-agl-demo-platform-crosssdk-'
          'aarch64-raspberrypi4-64-toolchain-13.0.3.sh',
        ),
      );
      expect(t.triple, 'aarch64-agl-linux');
      // AGL pins an old cmake → host build tools.
      expect(t.hostTools, isTrue);
      // Wayland backend with the agl-compositor shell client.
      expect(t.backends.keys, ['wayland-egl']);
      expect(t.backends['wayland-egl']!['BUILD_BACKEND_WAYLAND_EGL'], 'ON');
      expect(t.backends['wayland-egl']!['ENABLE_AGL_SHELL_CLIENT'], 'ON');
      expect(t.package?.bin, 'shell/homescreen');
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

    test('top-level image_url folds into a sysroot block that omits it', () {
      // A `sysroot:` block carrying only dev_packages/partition still picks up
      // the convenience top-level image_url.
      final t = CrossTarget.fromMap(const {
        'provider': 'arm-gnu',
        'image_url': 'https://example/x.img.xz',
        'sysroot': {
          'partition': 2,
          'dev_packages': ['libdrm-dev'],
        },
      });
      expect(t.sysroot?.source, SysrootProvenance.image);
      expect(t.imageUrl, 'https://example/x.img.xz');
      expect(t.sysroot?.devPackages, ['libdrm-dev']);
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

    test('parses the package: block for --deb', () {
      final t = CrossTarget.fromMap(const {
        'provider': 'arm-gnu',
        'image_url': 'https://example/x.img.xz',
        'package': {
          'name': 'ivi-homescreen',
          'version': '1.0.0',
          'maintainer': 'Me <me@x>',
          'bin': 'shell/homescreen',
          'install_dir': '/usr/bin',
          'depends': ['libfoo1'],
        },
      });
      expect(t.package, isNotNull);
      expect(t.package!.name, 'ivi-homescreen');
      expect(t.package!.version, '1.0.0');
      expect(t.package!.bin, 'shell/homescreen');
      expect(t.package!.installDir, '/usr/bin');
      expect(t.package!.depends, ['libfoo1']);
      expect(t.package!.autoDepends, isTrue); // default
    });

    test('parses package.files: and the flatpak: sub-block', () {
      final t = CrossTarget.fromMap(const {
        'provider': 'arm-gnu',
        'image_url': 'https://example/x.img.xz',
        'package': {
          'name': 'ivi-homescreen',
          'bin': 'shell/homescreen',
          'files': {
            'assets/app.toml': '/etc/ivi/app.toml',
            'assets/99-input.rules': '/lib/udev/rules.d/99-input.rules',
          },
          'flatpak': {
            'app_id': 'com.toyota.ivi.Homescreen',
            'runtime_version': '23.08',
            'finish_args': ['--socket=wayland', '--device=dri'],
            'icon': 'assets/icon.png',
            'categories': ['Utility', 'AudioVideo'],
          },
        },
      });
      // Shared files map (used by both --deb and --flatpak).
      expect(t.package!.files, {
        'assets/app.toml': '/etc/ivi/app.toml',
        'assets/99-input.rules': '/lib/udev/rules.d/99-input.rules',
      });
      // Flatpak sub-block.
      final fp = t.package!.flatpak;
      expect(fp, isNotNull);
      expect(fp!.appId, 'com.toyota.ivi.Homescreen');
      expect(fp.runtimeVersion, '23.08');
      expect(fp.runtime, 'org.freedesktop.Platform'); // default
      expect(fp.branch, 'stable'); // default
      expect(fp.finishArgs, ['--socket=wayland', '--device=dri']);
      expect(fp.icon, 'assets/icon.png');
      expect(fp.categories, ['Utility', 'AudioVideo']);
    });

    test('parses package.files map form with an explicit mode', () {
      final t = CrossTarget.fromMap(const {
        'provider': 'arm-gnu',
        'image_url': 'https://example/x.img.xz',
        'package': {
          'name': 'app',
          'bin': 'app',
          'files': {
            'assets/app.toml': '/etc/app/app.toml', // bare string → no mode
            'tools/helper': {'to': '/usr/bin/helper', 'mode': '0755'},
            'libs/libfoo.so': {'dest': '/usr/lib/libfoo.so'}, // map, no mode
          },
        },
      });
      // Both string and map forms populate the dest map.
      expect(t.package!.files, {
        'assets/app.toml': '/etc/app/app.toml',
        'tools/helper': '/usr/bin/helper',
        'libs/libfoo.so': '/usr/lib/libfoo.so',
      });
      // Only the entry with an explicit mode appears in fileModes.
      expect(t.package!.fileModes, {'tools/helper': '0755'});
    });

    test('package.files defaults to empty and flatpak to null', () {
      final t = CrossTarget.fromMap(const {
        'provider': 'arm-gnu',
        'image_url': 'https://example/x.img.xz',
        'package': {'name': 'app', 'bin': 'app'},
      });
      expect(t.package!.files, isEmpty);
      expect(t.package!.scripts, isEmpty);
      expect(t.package!.flatpak, isNull);
    });

    test('parses package.ipk.arch (opkg arch override)', () {
      final t = CrossTarget.fromMap(const {
        'provider': 'arm-gnu',
        'image_url': 'https://example/x.img.xz',
        'package': {
          'name': 'app',
          'bin': 'app',
          'ipk': {'arch': 'cortexa53'},
        },
      });
      expect(t.package!.ipk, isNotNull);
      expect(t.package!.ipk!.arch, 'cortexa53');
    });

    test('package.ipk defaults to null', () {
      final t = CrossTarget.fromMap(const {
        'provider': 'arm-gnu',
        'image_url': 'https://example/x.img.xz',
        'package': {'name': 'app', 'bin': 'app'},
      });
      expect(t.package!.ipk, isNull);
    });

    test('parses package.rpm: (license/release/group)', () {
      final t = CrossTarget.fromMap(const {
        'provider': 'arm-gnu',
        'image_url': 'https://example/x.img.xz',
        'package': {
          'name': 'app',
          'bin': 'app',
          'rpm': {
            'license': 'MIT',
            'release': '3',
            'group': 'Applications/System',
          },
        },
      });
      expect(t.package!.rpm, isNotNull);
      expect(t.package!.rpm!.license, 'MIT');
      expect(t.package!.rpm!.release, '3');
      expect(t.package!.rpm!.group, 'Applications/System');
    });

    test('package.rpm defaults: release 1, null license/group', () {
      final t = CrossTarget.fromMap(const {
        'provider': 'arm-gnu',
        'image_url': 'https://example/x.img.xz',
        'package': {
          'name': 'app',
          'bin': 'app',
          'rpm': {'group': 'Apps'},
        },
      });
      expect(t.package!.rpm!.license, isNull);
      expect(t.package!.rpm!.release, '1');
      expect(t.package!.rpm!.group, 'Apps');
    });

    test('package.rpm defaults to null', () {
      final t = CrossTarget.fromMap(const {
        'provider': 'arm-gnu',
        'image_url': 'https://example/x.img.xz',
        'package': {'name': 'app', 'bin': 'app'},
      });
      expect(t.package!.rpm, isNull);
    });

    test('parses package.scripts: (deb maintainer scripts)', () {
      final t = CrossTarget.fromMap(const {
        'provider': 'arm-gnu',
        'image_url': 'https://example/x.img.xz',
        'package': {
          'name': 'app',
          'bin': 'app',
          'scripts': {
            'postinst': 'debian/postinst.sh',
            'prerm': 'debian/prerm.sh',
          },
        },
      });
      expect(t.package!.scripts, {
        'postinst': 'debian/postinst.sh',
        'prerm': 'debian/prerm.sh',
      });
    });

    test('parses flatpak env:, args: and vendor_libs:', () {
      final t = CrossTarget.fromMap(const {
        'provider': 'arm-gnu',
        'package': {
          'flatpak': {
            'app_id': 'com.example.App',
            'env': {'IHS_LOG_LEVEL': 'info', 'GIO_USE_PROXY_RESOLVER': 'dummy'},
            'args': ['--backend=wayland-egl', '--shell=xdg'],
            'vendor_libs': 'auto',
          },
        },
      });
      final fp = t.package!.flatpak!;
      expect(fp.env, {
        'IHS_LOG_LEVEL': 'info',
        'GIO_USE_PROXY_RESOLVER': 'dummy',
      });
      expect(fp.args, ['--backend=wayland-egl', '--shell=xdg']);
      expect(fp.vendorLibs, isTrue);
    });

    test('flatpak env, args and vendor_libs default to empty/off', () {
      final t = CrossTarget.fromMap(const {
        'provider': 'arm-gnu',
        'package': {
          'flatpak': {'app_id': 'com.example.App'},
        },
      });
      final fp = t.package!.flatpak!;
      expect(fp.env, isEmpty);
      expect(fp.args, isEmpty);
      expect(fp.vendorLibs, isFalse);
    });

    test('vendor_libs: accepts a bool as well as the auto token', () {
      CrossTarget spec(Object? v) => CrossTarget.fromMap({
        'provider': 'arm-gnu',
        'package': {
          'flatpak': {'app_id': 'com.example.App', 'vendor_libs': v},
        },
      });
      expect(spec(true).package!.flatpak!.vendorLibs, isTrue);
      expect(spec('off').package!.flatpak!.vendorLibs, isFalse);
      expect(spec(false).package!.flatpak!.vendorLibs, isFalse);
    });

    test('flatpak app_id accepts the id: alias', () {
      final t = CrossTarget.fromMap(const {
        'provider': 'arm-gnu',
        'package': {
          'flatpak': {'id': 'com.example.App'},
        },
      });
      expect(t.package!.flatpak!.appId, 'com.example.App');
    });

    test('parses shared defines: and raw cmake_args:', () {
      final t = CrossTarget.fromMap(const {
        'provider': 'arm-gnu',
        'image_url': 'https://example/x.img.xz',
        'defines': {'CMAKE_INSTALL_PREFIX': '/usr', 'DEBUG': 'ON'},
        'cmake_args': ['-Wno-dev', '--fresh'],
      });
      expect(t.defines, {'CMAKE_INSTALL_PREFIX': '/usr', 'DEBUG': 'ON'});
      expect(t.cmakeArgs, ['-Wno-dev', '--fresh']);
    });

    test('defines/cmake_args default to empty when absent', () {
      final t = CrossTarget.fromMap(const {
        'provider': 'arm-gnu',
        'image_url': 'https://example/x.img.xz',
      });
      expect(t.defines, isEmpty);
      expect(t.cmakeArgs, isEmpty);
    });

    test('package: defaults when absent', () {
      final t = CrossTarget.fromMap(const {
        'provider': 'arm-gnu',
        'image_url': 'https://example/x.img.xz',
      });
      expect(t.package, isNull);
    });

    test('parses sysroot.dev_packages (root-free -dev set)', () {
      final t = CrossTarget.fromMap(const {
        'provider': 'arm-gnu',
        'sysroot': {
          'source': 'image',
          'image_url': 'https://example/x.img.xz',
          'dev_packages': [
            'https://repo/libdrm-dev_2.4_arm64.deb',
            'https://repo/libegl-dev_1.0_arm64.deb',
          ],
        },
      });
      expect(t.sysroot?.devPackages, hasLength(2));
      expect(
        t.sysroot?.devPackages.first,
        endsWith('libdrm-dev_2.4_arm64.deb'),
      );
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

    test('parses launcher (defaults to none; unknown throws)', () {
      expect(
        CrossTarget.fromMap(const {
          'provider': 'arm-gnu',
          'launcher': 'ccache',
        }).launcher,
        Launcher.ccache,
      );
      expect(
        CrossTarget.fromMap(const {'provider': 'arm-gnu'}).launcher,
        Launcher.none,
      );
      expect(
        () => CrossTarget.fromMap(const {
          'provider': 'arm-gnu',
          'launcher': 'nope',
        }),
        throwsArgumentError,
      );
    });

    test('host_build_tools (and host_cmake alias) parse to hostTools', () {
      expect(
        CrossTarget.fromMap(const {'provider': 'yocto-sdk'}).hostTools,
        isFalse,
      );
      expect(
        CrossTarget.fromMap(const {
          'provider': 'yocto-sdk',
          'host_build_tools': true,
        }).hostTools,
        isTrue,
      );
      // Backward-compatible alias.
      expect(
        CrossTarget.fromMap(const {
          'provider': 'yocto-sdk',
          'host_cmake': true,
        }).hostTools,
        isTrue,
      );
    });

    test('augment host: true parses (defaults to false)', () {
      final t = CrossTarget.fromMap(const {
        'provider': 'arm-gnu',
        'augment': [
          {
            'pkg': 'wayland-cxx-scanner',
            'url': 'https://example/scanner.tar.gz',
            'build': 'cmake',
            'host': true,
          },
          {'pkg': 'libdisplay-info', 'url': 'https://example/ldi.tar.gz'},
        ],
      });
      final scanner = t.augment.firstWhere(
        (a) => a.pkg == 'wayland-cxx-scanner',
      );
      expect(scanner.host, isTrue);
      expect(scanner.build, CrossGenerator.cmake);
      // A normal target augment defaults host to false.
      expect(
        t.augment.firstWhere((a) => a.pkg == 'libdisplay-info').host,
        isFalse,
      );
    });

    test('host_dev_packages parse (defaults to empty)', () {
      expect(
        CrossTarget.fromMap(const {'provider': 'arm-gnu'}).hostDevPackages,
        isEmpty,
      );
      expect(
        CrossTarget.fromMap(const {
          'provider': 'arm-gnu',
          'host_dev_packages': ['libpugixml-dev'],
        }).hostDevPackages,
        ['libpugixml-dev'],
      );
    });
  });
}
