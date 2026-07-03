import 'package:emb_cli/src/cross/cross_keys.dart';
import 'package:emb_cli/src/cross/cross_target.dart';
import 'package:test/test.dart';

CrossTarget _t(Map<dynamic, dynamic> m) => CrossTarget.fromMap(m);

void main() {
  group('cross keys', () {
    final rpi5 = _t(const {
      'provider': 'arm-gnu',
      'toolchain_version': '12.3.rel1',
      'image_url': 'https://example/raspios.img.xz',
      'cpu_flags': ['-mcpu=cortex-a76'],
    });
    final rpi4 = _t(const {
      'provider': 'arm-gnu',
      'toolchain_version': '12.3.rel1',
      'image_url': 'https://example/raspios.img.xz',
      'cpu_flags': ['-mcpu=cortex-a72'],
    });
    final radxa = _t(const {
      'provider': 'arm-gnu',
      'toolchain_version': '12.3.rel1',
      'image_url': 'https://example/radxa.img.xz',
      'cpu_flags': ['-mcpu=cortex-a55'],
    });

    test('cpu-only variants share a sysrootKey but differ in buildKey', () {
      // rpi4/rpi5: same image + toolchain, only -mcpu differs.
      expect(sysrootKey(rpi5), sysrootKey(rpi4));
      expect(buildKey(rpi5), isNot(buildKey(rpi4)));
    });

    test('a different image yields a different sysrootKey', () {
      expect(sysrootKey(radxa), isNot(sysrootKey(rpi5)));
    });

    test('keys are deterministic and 12 hex chars', () {
      expect(sysrootKey(rpi5), sysrootKey(rpi5));
      expect(buildKey(rpi5), matches(RegExp(r'^[0-9a-f]{12}$')));
      expect(sysrootKey(rpi5), matches(RegExp(r'^[0-9a-f]{12}$')));
    });

    test('backends/defines change the buildKey but not the sysrootKey', () {
      final withBackend = _t(const {
        'provider': 'arm-gnu',
        'toolchain_version': '12.3.rel1',
        'image_url': 'https://example/raspios.img.xz',
        'cpu_flags': ['-mcpu=cortex-a76'],
        'backends': {
          'drm-kms-egl': {'BUILD_BACKEND_DRM_KMS_EGL': 'ON'},
        },
      });
      expect(sysrootKey(withBackend), sysrootKey(rpi5));
      expect(buildKey(withBackend), isNot(buildKey(rpi5)));
    });

    test('sysrootBaseKey excludes augments but tracks the sysroot inputs', () {
      final withAugment = _t(const {
        'provider': 'arm-gnu',
        'toolchain_version': '12.3.rel1',
        'image_url': 'https://example/raspios.img.xz',
        'cpu_flags': ['-mcpu=cortex-a76'],
        'augment': [
          {
            'pkg': 'libdisplay-info',
            'min': '0.2.0',
            'url': 'https://x/libdisplay-info.tar.gz',
            'build': 'meson',
          },
        ],
      });
      // Same image/toolchain, no augment → different sysrootKey, SAME base key.
      expect(sysrootBaseKey(withAugment), sysrootBaseKey(rpi5));
      expect(sysrootKey(withAugment), isNot(sysrootKey(rpi5)));
      // But a different image or dev_packages does change the base key.
      final withDev = _t(const {
        'provider': 'arm-gnu',
        'toolchain_version': '12.3.rel1',
        'image_url': 'https://example/raspios.img.xz',
        'cpu_flags': ['-mcpu=cortex-a76'],
        'sysroot': {
          'dev_packages': ['libfoo-dev'],
        },
      });
      expect(sysrootBaseKey(withDev), isNot(sysrootBaseKey(rpi5)));
      expect(sysrootBaseKey(rpi5), matches(RegExp(r'^[0-9a-f]{12}$')));
    });

    test('modules change the buildKey but not the sysroot keys', () {
      final withModule = _t(const {
        'provider': 'arm-gnu',
        'toolchain_version': '12.3.rel1',
        'image_url': 'https://example/raspios.img.xz',
        'cpu_flags': ['-mcpu=cortex-a76'],
        'modules': [
          {
            'name': 'hello',
            'path': 'native/hello',
            'build': 'cmake',
            'artifacts': ['libhello.so'],
          },
        ],
      });
      expect(buildKey(withModule), isNot(buildKey(rpi5)));
      // Modules are a build-tier input; the sysroot is untouched.
      expect(sysrootKey(withModule), sysrootKey(rpi5));
      expect(sysrootBaseKey(withModule), sysrootBaseKey(rpi5));

      // A change to a module's defines flips the buildKey.
      final withDefine = _t(const {
        'provider': 'arm-gnu',
        'toolchain_version': '12.3.rel1',
        'image_url': 'https://example/raspios.img.xz',
        'cpu_flags': ['-mcpu=cortex-a76'],
        'modules': [
          {
            'name': 'hello',
            'path': 'native/hello',
            'build': 'cmake',
            'artifacts': ['libhello.so'],
            'defines': {'HELLO_FAST': 'ON'},
          },
        ],
      });
      expect(buildKey(withDefine), isNot(buildKey(withModule)));
    });

    test('launcher does not change the buildKey (not a build output)', () {
      final withLauncher = _t(const {
        'provider': 'arm-gnu',
        'toolchain_version': '12.3.rel1',
        'image_url': 'https://example/raspios.img.xz',
        'cpu_flags': ['-mcpu=cortex-a76'],
        'launcher': 'ccache',
      });
      expect(withLauncher.launcher, Launcher.ccache);
      expect(buildKey(withLauncher), buildKey(rpi5));
      expect(sysrootKey(withLauncher), sysrootKey(rpi5));
    });

    test('sysroot symlinks change the sysrootKey', () {
      final withLink = _t(const {
        'provider': 'arm-gnu',
        'toolchain_version': '12.3.rel1',
        'image_url': 'https://example/raspios.img.xz',
        'cpu_flags': ['-mcpu=cortex-a76'],
        'sysroot': {
          'symlinks': {'usr/include/drm': 'libdrm'},
        },
      });
      // Same toolchain/image, but the sysroot content differs.
      expect(sysrootKey(withLink), isNot(sysrootKey(rpi5)));
    });

    test('a snapshot date changes the sysrootBaseKey', () {
      CrossTarget snap(String? date) => _t({
        'provider': 'arm-gnu',
        'toolchain_version': '12.3.rel1',
        'image_url': 'https://example/raspios.img.xz',
        'cpu_flags': const ['-mcpu=cortex-a76'],
        'sysroot': {
          'dev_packages': const ['libdrm-dev'],
          if (date != null) 'snapshot': date,
        },
      });
      // A different pin date must re-key so the sysroot re-extracts against the
      // new snapshot; the same date is stable.
      final jun = sysrootBaseKey(snap('2024-06-01'));
      expect(jun, isNot(sysrootBaseKey(snap(null))));
      expect(jun, isNot(sysrootBaseKey(snap('2024-07-01'))));
      expect(jun, sysrootBaseKey(snap('2024-06-01')));
    });
  });
}
