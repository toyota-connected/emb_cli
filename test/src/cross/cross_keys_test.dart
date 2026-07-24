import 'dart:io';

import 'package:emb_cli/src/cross/cross_keys.dart';
import 'package:emb_cli/src/cross/cross_target.dart';
import 'package:path/path.dart' as p;
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

    test('a requires_define-gated augment counts only when its gate is on', () {
      const sentry = {
        'pkg': 'sentry-native',
        'min': '0.15.3',
        'url': 'https://x/sentry.zip',
        'build': 'cmake',
        'requires_define': 'BUILD_CRASH_HANDLER',
      };
      // Gate unsatisfied (no define) → not staged → key unchanged.
      final gatedOff = _t(const {
        'provider': 'arm-gnu',
        'toolchain_version': '12.3.rel1',
        'image_url': 'https://example/raspios.img.xz',
        'cpu_flags': ['-mcpu=cortex-a76'],
        'augment': [sentry],
      });
      expect(sysrootKey(gatedOff), sysrootKey(rpi5));
      // Gate satisfied → staged → key changes.
      final gatedOn = _t(const {
        'provider': 'arm-gnu',
        'toolchain_version': '12.3.rel1',
        'image_url': 'https://example/raspios.img.xz',
        'cpu_flags': ['-mcpu=cortex-a76'],
        'defines': {'BUILD_CRASH_HANDLER': 'ON'},
        'augment': [sentry],
      });
      expect(sysrootKey(gatedOn), isNot(sysrootKey(rpi5)));
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

  group('augment patch keying', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('emb_keys_'));
    tearDown(() => tmp.deleteSync(recursive: true));

    String patch(String name, String body) {
      final f = File(p.join(tmp.path, name))..writeAsStringSync(body);
      return f.path;
    }

    CrossTarget withPatches(List<String> patches) => _t({
      'provider': 'arm-gnu',
      'toolchain_version': '12.3.rel1',
      'image_url': 'https://example/raspios.img.xz',
      'cpu_flags': const ['-mcpu=cortex-a76'],
      'augment': [
        {
          'pkg': 'filament',
          'min': '1.74.0',
          'url': 'https://example/filament-1.74.0.tar.gz',
          'build': 'cmake',
          'patches': patches,
        },
      ],
    });

    test('sysrootKey moves when a patch is edited in place', () {
      // The staleness this exists to prevent: url and min do not move when a
      // patch is edited, so without hashing contents a store entry built from
      // the previous series would be reused silently.
      final a = patch('0007.patch', 'original');
      final before = sysrootKey(withPatches([a]));
      File(a).writeAsStringSync('revised');
      expect(sysrootKey(withPatches([a])), isNot(before));
    });

    test('sysrootKey separates a patched augment from an unpatched one', () {
      final a = patch('0007.patch', 'diff');
      expect(sysrootKey(withPatches([a])), isNot(sysrootKey(withPatches([]))));
    });

    test('sysrootBaseKey ignores patches', () {
      // The base entry stays augment-independent, so one image extraction is
      // still shared across targets differing only in their augments.
      final a = patch('0007.patch', 'diff');
      expect(
        sysrootBaseKey(withPatches([a])),
        sysrootBaseKey(withPatches(const [])),
      );
    });

    test('augmentIdentity moves when subdir changes', () {
      // A subdir build produces different artifacts than the root build of the
      // same tarball, so the overlay must not be reused across the two.
      const common = {
        'pkg': 'ivi-homescreen-shared',
        'url': 'https://example/ivi.tar.gz',
        'build': 'cmake',
      };
      final root = AugmentLib.fromMap(common);
      final sub = AugmentLib.fromMap({...common, 'subdir': 'shared'});
      expect(augmentIdentity(sub), isNot(augmentIdentity(root)));
    });

    test('augmentOverlayKey separates cpu variants of one augment set', () {
      final a = patch('0007.patch', 'diff');
      final base = {
        'provider': 'arm-gnu',
        'toolchain_version': '12.3.rel1',
        'image_url': 'https://example/raspios.img.xz',
        'augment': [
          {
            'pkg': 'filament',
            'min': '1.74.0',
            'url': 'u',
            'patches': [a],
          },
        ],
      };
      final a76 = _t({
        ...base,
        'cpu_flags': const ['-mcpu=cortex-a76'],
      });
      final a72 = _t({
        ...base,
        'cpu_flags': const ['-mcpu=cortex-a72'],
      });
      // An overlay holds compiled objects, so unlike the sysroot base it must
      // never be shared across cpu variants.
      expect(augmentOverlayKey(a76), isNot(augmentOverlayKey(a72)));
    });

    test('augmentOverlayKey moves when a patch is edited in place', () {
      final a = patch('0007.patch', 'original');
      final before = augmentOverlayKey(withPatches([a]));
      File(a).writeAsStringSync('revised');
      expect(augmentOverlayKey(withPatches([a])), isNot(before));
    });

    test('augmentOverlayKey is stable for an unchanged series', () {
      final a = patch('0007.patch', 'diff');
      expect(
        augmentOverlayKey(withPatches([a])),
        augmentOverlayKey(withPatches([a])),
      );
    });

    test('a missing patch file still yields a distinct, stable key', () {
      // Key computation must not throw on an unresolvable path; that failure
      // belongs to the apply step, which reports it properly.
      final absent = p.join(tmp.path, 'absent.patch');
      final k = augmentOverlayKey(withPatches([absent]));
      expect(k, augmentOverlayKey(withPatches([absent])));
      expect(k, isNot(augmentOverlayKey(withPatches(const []))));
    });
  });

  group('augment patch resolution', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('emb_resolve_'));
    tearDown(() => tmp.deleteSync(recursive: true));

    CrossTarget target(List<String> patches) => _t({
      'provider': 'arm-gnu',
      'toolchain_version': '12.3.rel1',
      'image_url': 'https://example/raspios.img.xz',
      'augment': [
        {'pkg': 'filament', 'min': '1.74.0', 'url': 'u', 'patches': patches},
      ],
    });

    test('rebases relative paths onto the declaring manifest', () {
      final resolved = target([
        'patches/0007.patch',
      ]).withResolvedPatches('/ws/app/fluorite/emb.yaml');
      expect(resolved.augment.single.patches, [
        p.normalize('/ws/app/fluorite/patches/0007.patch'),
      ]);
    });

    test('leaves absolute paths and preserves other augment fields', () {
      final abs = p.join(p.separator, 'etc', '0001.patch');
      final a = target([
        abs,
      ]).withResolvedPatches('/ws/emb.yaml').augment.single;
      expect(a.patches, [abs]);
      expect(a.pkg, 'filament');
      expect(a.minVersion, '1.74.0');
      expect(a.url, 'u');
    });

    test('is a no-op without a declaring file or without patches', () {
      final t = target(['a.patch']);
      expect(identical(t.withResolvedPatches(null), t), isTrue);
      final none = target(const []);
      expect(identical(none.withResolvedPatches('/ws/emb.yaml'), none), isTrue);
    });

    test('makes the key independent of the working directory', () {
      // The bug this closes: unresolved relative paths hash to whatever they
      // point at from the process's cwd, so the key computed at one moment
      // need not describe the files that later get applied.
      Directory(p.join(tmp.path, 'a', 'patches')).createSync(recursive: true);
      Directory(p.join(tmp.path, 'b', 'patches')).createSync(recursive: true);
      File(
        p.join(tmp.path, 'a', 'patches', '0007.patch'),
      ).writeAsStringSync('from a');
      File(
        p.join(tmp.path, 'b', 'patches', '0007.patch'),
      ).writeAsStringSync('from b');

      final fromA = target([
        'patches/0007.patch',
      ]).withResolvedPatches(p.join(tmp.path, 'a', 'emb.yaml'));
      final fromB = target([
        'patches/0007.patch',
      ]).withResolvedPatches(p.join(tmp.path, 'b', 'emb.yaml'));

      // Same relative path, different manifests, different contents: the keys
      // must differ. Unresolved, both would hash the identical string.
      expect(sysrootKey(fromA), isNot(sysrootKey(fromB)));
      expect(augmentOverlayKey(fromA), isNot(augmentOverlayKey(fromB)));
    });
  });
}
