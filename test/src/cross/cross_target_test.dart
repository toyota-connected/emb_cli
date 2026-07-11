import 'package:emb_cli/src/cross/cross_profile.dart';
import 'package:emb_cli/src/cross/cross_target.dart';
import 'package:test/test.dart';

void main() {
  group('CrossTarget.withDefineOverrides', () {
    final base = CrossTarget.fromMap(const {
      'provider': 'arm-gnu',
      'triple': 'aarch64-none-linux-gnu',
      'defines': {'ENABLE_SENTRY': 'OFF', 'KEEP': '1'},
      'cmake_args': ['-Wno-dev'],
      'backends': {
        'wayland-egl': {
          'BUILD_BACKEND_WAYLAND_EGL': 'ON',
          'ENABLE_SENTRY': 'OFF',
        },
        'drm-kms': {'BUILD_BACKEND_DRM_KMS': 'ON'},
      },
    });

    test('an override beats the shared defines and every backend entry', () {
      final t = base.withDefineOverrides(const {'ENABLE_SENTRY': 'ON'});
      expect(t.defines, {'ENABLE_SENTRY': 'ON', 'KEEP': '1'});
      expect(t.backends['wayland-egl'], {
        'BUILD_BACKEND_WAYLAND_EGL': 'ON',
        'ENABLE_SENTRY': 'ON',
      });
      // A backend that never mentioned the key gets it too — the override is
      // the last word for every configure of this target.
      expect(t.backends['drm-kms'], {
        'BUILD_BACKEND_DRM_KMS': 'ON',
        'ENABLE_SENTRY': 'ON',
      });
    });

    test('a new key is added; unrelated fields carry over', () {
      final t = base.withDefineOverrides(const {'NEW_KEY': 'x'});
      expect(t.defines['NEW_KEY'], 'x');
      expect(t.targetTriple, base.targetTriple);
      expect(t.cmakeArgs, base.cmakeArgs);
      expect(t.provider, base.provider);
    });

    test('empty overrides return the same instance', () {
      expect(identical(base.withDefineOverrides(const {}), base), isTrue);
    });

    test('does not mutate the original', () {
      base.withDefineOverrides(const {'ENABLE_SENTRY': 'ON'});
      expect(base.defines['ENABLE_SENTRY'], 'OFF');
      expect(base.backends['wayland-egl']!['ENABLE_SENTRY'], 'OFF');
    });

    test('applies several overrides in one call', () {
      final t = base.withDefineOverrides(const {
        'ENABLE_SENTRY': 'ON',
        'NEW': 'y',
      });
      expect(t.defines, {'ENABLE_SENTRY': 'ON', 'KEEP': '1', 'NEW': 'y'});
      expect(t.backends['wayland-egl'], {
        'BUILD_BACKEND_WAYLAND_EGL': 'ON',
        'ENABLE_SENTRY': 'ON',
        'NEW': 'y',
      });
    });

    test('a value is carried verbatim, spaces and all', () {
      final t = base.withDefineOverrides(const {
        'CMAKE_CXX_FLAGS': '-O2 -DNDEBUG',
      });
      expect(t.defines['CMAKE_CXX_FLAGS'], '-O2 -DNDEBUG');
      expect(t.backends['drm-kms']!['CMAKE_CXX_FLAGS'], '-O2 -DNDEBUG');
    });

    test('an empty override value is applied (CMake unset-style)', () {
      final t = base.withDefineOverrides(const {'ENABLE_SENTRY': ''});
      expect(t.defines['ENABLE_SENTRY'], '');
      expect(t.backends['wayland-egl']!['ENABLE_SENTRY'], '');
    });

    test('the generator is preserved so it works for meson too', () {
      final meson = CrossTarget.fromMap(const {
        'provider': 'arm-gnu',
        'triple': 'aarch64-none-linux-gnu',
        'generator': 'meson',
        'defines': {'backend': 'drm-gl'},
      });
      final t = meson.withDefineOverrides(const {'backend': 'wayland'});
      expect(t.generator, CrossGenerator.meson);
      expect(t.defines['backend'], 'wayland');
    });
  });

  group('CrossTarget.parseDefineOverrides', () {
    test('splits on the first = only', () {
      expect(CrossTarget.parseDefineOverrides(const ['A=b=c']), {'A': 'b=c'});
    });

    test('allows an empty value (CMake unset-style)', () {
      expect(CrossTarget.parseDefineOverrides(const ['FOO=']), {'FOO': ''});
    });

    test('the last occurrence of a repeated key wins', () {
      expect(CrossTarget.parseDefineOverrides(const ['A=1', 'A=2']), {
        'A': '2',
      });
    });

    test('a missing = or an empty key is a FormatException', () {
      expect(
        () => CrossTarget.parseDefineOverrides(const ['NOEQ']),
        throwsFormatException,
      );
      expect(
        () => CrossTarget.parseDefineOverrides(const ['=v']),
        throwsFormatException,
      );
    });
  });

  group('CrossTarget.defineSatisfied', () {
    test('a null or blank gate always includes', () {
      expect(CrossTarget.defineSatisfied(null, const {}), isTrue);
      expect(CrossTarget.defineSatisfied('', const {}), isTrue);
      expect(CrossTarget.defineSatisfied('   ', const {}), isTrue);
    });

    test('a bare name includes only when the define is truthy', () {
      for (final v in const ['ON', 'on', 'true', 'TRUE', '1', 'yes', 'y']) {
        expect(
          CrossTarget.defineSatisfied('BUILD_CRASH_HANDLER', {
            'BUILD_CRASH_HANDLER': v,
          }),
          isTrue,
          reason: 'value "$v" should read as truthy',
        );
      }
    });

    test('a bare name is excluded when the define is falsy or absent', () {
      for (final v in const ['OFF', 'off', '0', 'no', '']) {
        expect(
          CrossTarget.defineSatisfied('BUILD_CRASH_HANDLER', {
            'BUILD_CRASH_HANDLER': v,
          }),
          isFalse,
          reason: 'value "$v" should read as falsy',
        );
      }
      expect(
        CrossTarget.defineSatisfied('BUILD_CRASH_HANDLER', const {}),
        isFalse,
      );
    });

    test('a name=value gate matches the exact value only', () {
      expect(
        CrossTarget.defineSatisfied('MODE=release', const {'MODE': 'release'}),
        isTrue,
      );
      expect(
        CrossTarget.defineSatisfied('MODE=release', const {'MODE': 'debug'}),
        isFalse,
      );
      expect(CrossTarget.defineSatisfied('MODE=release', const {}), isFalse);
    });
  });

  group('AugmentLib.fromMap requires_define', () {
    test('reads requires_define', () {
      final a = AugmentLib.fromMap(const {
        'pkg': 'sentry-native',
        'url': 'https://example/sentry.zip',
        'build': 'cmake',
        'requires_define': 'BUILD_CRASH_HANDLER',
      });
      expect(a.requiresDefine, 'BUILD_CRASH_HANDLER');
    });

    test('accepts the when alias', () {
      final a = AugmentLib.fromMap(const {
        'pkg': 'foo',
        'url': 'u',
        'when': 'ENABLE_FOO',
      });
      expect(a.requiresDefine, 'ENABLE_FOO');
    });

    test('defaults to null so the augment always builds', () {
      final a = AugmentLib.fromMap(const {'pkg': 'foo', 'url': 'u'});
      expect(a.requiresDefine, isNull);
    });
  });

  group('PackageSpec.fromMap files requires_define', () {
    test('captures a per-file gate; ungated files stay ungated', () {
      final spec = PackageSpec.fromMap(const {
        'files': {
          'overlay/usr/bin/crashpad_handler': {
            'to': '/usr/bin/crashpad_handler',
            'mode': '0755',
            'requires_define': 'BUILD_CRASH_HANDLER',
          },
          'assets/logo.png': {
            'to': '/usr/share/app/logo.png',
            'when': 'ENABLE_UI',
          },
          'README': '/usr/share/doc/app/README',
        },
      });
      expect(
        spec.files['overlay/usr/bin/crashpad_handler'],
        '/usr/bin/crashpad_handler',
      );
      expect(spec.fileModes['overlay/usr/bin/crashpad_handler'], '0755');
      expect(
        spec.fileRequires['overlay/usr/bin/crashpad_handler'],
        'BUILD_CRASH_HANDLER',
      );
      expect(spec.fileRequires['assets/logo.png'], 'ENABLE_UI');
      expect(spec.fileRequires.containsKey('README'), isFalse);
    });
  });

  group('PackageSpec.fromMap bundle_libs', () {
    test('defaults to false when absent', () {
      expect(const PackageSpec().bundleLibs, isFalse);
      expect(PackageSpec.fromMap(const {'bin': 'server'}).bundleLibs, isFalse);
    });

    test('reads bundle_libs: true', () {
      final spec = PackageSpec.fromMap(const {
        'bin': 'server',
        'bundle_libs': true,
      });
      expect(spec.bundleLibs, isTrue);
    });
  });
}
