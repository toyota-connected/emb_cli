import 'package:emb_cli/src/cross/cross_keys.dart';
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

  group('AugmentLib.fromMap subdir', () {
    test('reads subdir', () {
      final a = AugmentLib.fromMap(const {
        'pkg': 'ivi-homescreen-shared',
        'url': 'https://example/ivi.tar.gz',
        'build': 'cmake',
        'subdir': 'shared',
      });
      expect(a.subdir, 'shared');
    });

    test('accepts the source_subdir alias', () {
      final a = AugmentLib.fromMap(const {
        'pkg': 'foo',
        'url': 'u',
        'source_subdir': 'lib/foo',
      });
      expect(a.subdir, 'lib/foo');
    });

    test('defaults to null so the root is configured', () {
      final a = AugmentLib.fromMap(const {'pkg': 'foo', 'url': 'u'});
      expect(a.subdir, isNull);
    });

    test('survives resolvePatchesAgainst', () {
      final a = AugmentLib.fromMap(const {
        'pkg': 'foo',
        'url': 'u',
        'subdir': 'shared',
        'patches': ['p/0001.patch'],
      }).resolvePatchesAgainst('/work/manifest.yaml');
      expect(a.subdir, 'shared');
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

  group('CrossTarget.fromMap run_command', () {
    test('parses run_command: as a list of strings', () {
      final t = CrossTarget.fromMap(const {
        'provider': 'arm-gnu',
        'triple': 'aarch64-none-linux-gnu',
        'run_command': [r'./${embedder}', '--config', '/etc/app.conf', '-b', '.'],
      });
      expect(
        t.runCommand,
        [r'./${embedder}', '--config', '/etc/app.conf', '-b', '.'],
      );
    });

    test('absent run_command: leaves the field null', () {
      final t = CrossTarget.fromMap(const {
        'provider': 'arm-gnu',
        'triple': 'aarch64-none-linux-gnu',
      });
      expect(t.runCommand, isNull);
    });

    test('survives withDefineOverrides', () {
      final t = CrossTarget.fromMap(const {
        'provider': 'arm-gnu',
        'triple': 'aarch64-none-linux-gnu',
        'run_command': ['./custom', '-b', '.'],
      });
      final overridden = t.withDefineOverrides(const {'X': '1'});
      expect(overridden.runCommand, ['./custom', '-b', '.']);
    });
  });

  group('CrossTarget.gatedAugments', () {
    // Two variants of one package, gated against each other. They install into
    // the same overlay prefix, so building both means the last one wins and
    // the gate decided nothing -- which is what `--prepare` used to do.
    CrossTarget target(String value) => CrossTarget.fromMap({
      'provider': 'arm-gnu',
      'triple': 'aarch64-none-linux-gnu',
      'defines': {'WITH_FIRESTORE': value},
      'augment': const [
        {
          'pkg': 'sdk',
          'when': 'WITH_FIRESTORE=OFF',
          'url': 'a',
          'build': 'cmake',
        },
        {
          'pkg': 'sdk',
          'when': 'WITH_FIRESTORE=ON',
          'url': 'b',
          'build': 'cmake',
        },
        {'pkg': 'always', 'url': 'c', 'build': 'cmake'},
      ],
    });

    test('selects one variant of a mutually gated pair, plus the ungated', () {
      final off = target('OFF');
      expect(off.gatedAugments().map((a) => a.url), ['a', 'c']);
      expect(off.skippedAugments().map((a) => a.url), ['b']);

      final on = target('ON');
      expect(on.gatedAugments().map((a) => a.url), ['b', 'c']);
      expect(on.skippedAugments().map((a) => a.url), ['a']);
    });

    test('a CLI -D override moves the selection', () {
      final overridden = target(
        'OFF',
      ).withDefineOverrides(const {'WITH_FIRESTORE': 'ON'});
      expect(overridden.gatedAugments().map((a) => a.url), ['b', 'c']);
    });

    test('gated and skipped together account for every augment', () {
      final t = target('ON');
      expect(
        t.gatedAugments().length + t.skippedAugments().length,
        t.augment.length,
      );
    });
  });

  group('SysrootSpec transport', () {
    SysrootSpec? specOf(Map<String, dynamic> sysroot) => CrossTarget.fromMap({
      'provider': 'arm-gnu',
      'sysroot': sysroot,
    }).sysroot;

    test('defaults to ssh with no serial', () {
      final s = specOf({'source': 'device', 'host': 'pi@board'})!;
      expect(s.transport, DeviceTransport.ssh);
      expect(s.adbSerial, isNull);
    });

    test('transport: adb is parsed', () {
      final s = specOf({'source': 'device', 'transport': 'adb'})!;
      expect(s.transport, DeviceTransport.adb);
    });

    test('adb_serial and its serial alias both parse', () {
      expect(specOf({'transport': 'adb', 'adb_serial': 'A1'})!.adbSerial, 'A1');
      expect(specOf({'transport': 'adb', 'serial': 'B2'})!.adbSerial, 'B2');
    });

    test('transport is read even when the source is an image', () {
      // Pushing a bundle is a separate concern from where the sysroot came
      // from: an image-sourced sysroot can still deploy over adb.
      final s = specOf({
        'source': 'image',
        'image_url': 'https://example.com/x.img.xz',
        'transport': 'adb',
      })!;
      expect(s.source, SysrootProvenance.image);
      expect(s.transport, DeviceTransport.adb);
    });

    test('an unknown transport token falls back to ssh', () {
      expect(
        specOf({'transport': 'carrier-pigeon'})!.transport,
        DeviceTransport.ssh,
      );
    });

    test('ssh_port/ssh_opts still parse alongside a transport', () {
      final s = specOf({
        'source': 'device',
        'host': 'pi@board',
        'ssh_port': 2222,
        'ssh_opts': '-o StrictHostKeyChecking=no',
      })!;
      expect(s.sshPort, 2222);
      expect(s.sshOpts, '-o StrictHostKeyChecking=no');
      expect(s.transport, DeviceTransport.ssh);
    });
  });

  group('CrossTarget.embedderExports', () {
    CrossTarget targetOf(Object? raw) => CrossTarget.fromMap({
      'provider': 'arm-gnu',
      'triple': 'aarch64-none-linux-gnu',
      if (raw != null) 'embedder_exports': raw,
    });

    test('absent means nothing is staged out of the embedder build', () {
      expect(targetOf(null).embedderExports, isEmpty);
    });

    test('entries are build-tree subdirectories, kept in order', () {
      expect(targetOf(['shared', 'plugins/common']).embedderExports, [
        'shared',
        'plugins/common',
      ]);
    });

    test('a non-string entry is stringified rather than dropped', () {
      // Dropping it would stage less than the manifest asked for, which is the
      // failure this feature exists to prevent -- fail at install instead.
      expect(targetOf([42]).embedderExports, ['42']);
    });

    test('survives withDefineOverrides and withResolvedPatches', () {
      final t = targetOf(['shared']);
      expect(t.withDefineOverrides(const {'X': '1'}).embedderExports, [
        'shared',
      ]);
      expect(t.withResolvedPatches('/tmp/board.emb.yaml').embedderExports, [
        'shared',
      ]);
    });
  });

  group('FlatpakPackageSpec.vendorLibs', () {
    bool vendorOf(Object? raw) => FlatpakPackageSpec.fromMap({
      'app_id': 'com.example.App',
      if (raw != null) 'vendor_libs': raw,
    }).vendorLibs;

    test('absent is off', () {
      expect(vendorOf(null), isFalse);
    });

    test('auto, on and true are on', () {
      expect(vendorOf('auto'), isTrue);
      expect(vendorOf('ON'), isTrue);
      expect(vendorOf(true), isTrue);
    });

    test('off, false and none are off', () {
      expect(vendorOf('off'), isFalse);
      expect(vendorOf(false), isFalse);
      expect(vendorOf('none'), isFalse);
    });

    test('a token it does not know is refused, not read as off', () {
      // Read as off, a typo ships a flatpak that fails at first launch on the
      // target -- the failure vendoring exists to prevent.
      expect(() => vendorOf('atuo'), throwsA(isA<ArgumentError>()));
      expect(() => vendorOf('enabled'), throwsA(isA<ArgumentError>()));
    });
  });

  group('AugmentLib source declarations', () {
    AugmentLib augmentOf(Map<String, Object?> extra) =>
        AugmentLib.fromMap({'pkg': 'libfoo', ...extra});

    test('a url augment is not local', () {
      final a = augmentOf({'url': 'https://x/libfoo-1.2.tar.gz'});
      expect(a.isLocal, isFalse);
      expect(a.path, isNull);
    });

    test('a path augment is local and keeps its path', () {
      final a = augmentOf({'path': '../libfoo'});
      expect(a.isLocal, isTrue);
      expect(a.path, '../libfoo');
      expect(a.url, isEmpty);
    });

    test('declaring both sources is refused', () {
      expect(
        () => augmentOf({'url': 'https://x/libfoo.tar.gz', 'path': '../foo'}),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('declaring neither source is refused', () {
      expect(() => augmentOf({}), throwsA(isA<ArgumentError>()));
    });

    test('patches with a local path are refused', () {
      // emb would be rewriting files it did not create.
      expect(
        () => augmentOf({
          'path': '../libfoo',
          'patches': ['fix.patch'],
        }),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('a local path resolves against the declaring manifest', () {
      final a = augmentOf({
        'path': '../libfoo',
      }).resolvePatchesAgainst('/w/boards/pi5.emb.yaml');
      expect(a.path, '/w/libfoo');
    });

    test('an absolute local path is left alone', () {
      final a = augmentOf({
        'path': '/src/libfoo',
      }).resolvePatchesAgainst('/w/boards/pi5.emb.yaml');
      expect(a.path, '/src/libfoo');
    });

    test('two checkouts of one package key differently', () {
      final a = augmentOf({'path': '/src/a'});
      final b = augmentOf({'path': '/src/b'});
      expect(augmentIdentity(a), isNot(augmentIdentity(b)));
    });
  });
}
