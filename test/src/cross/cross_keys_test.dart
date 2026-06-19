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
  });
}
