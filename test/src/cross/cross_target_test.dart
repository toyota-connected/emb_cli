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
}
