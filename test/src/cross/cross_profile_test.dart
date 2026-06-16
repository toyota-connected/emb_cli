import 'package:emb_cli/src/cross/cross_profile.dart';
import 'package:test/test.dart';

void main() {
  group('PkgConfig.toEnv', () {
    test('emits libdir/path only when non-empty', () {
      const bare = PkgConfig(sysrootDir: '/sr');
      expect(bare.toEnv(), {'PKG_CONFIG_SYSROOT_DIR': '/sr'});

      const full = PkgConfig(
        sysrootDir: '/sr',
        libdir: ['/a', '/b'],
        path: ['/c'],
      );
      expect(full.toEnv(), {
        'PKG_CONFIG_LIBDIR': '/a:/b',
        'PKG_CONFIG_SYSROOT_DIR': '/sr',
        'PKG_CONFIG_PATH': '/c',
      });
    });
  });

  group('CrossProfile', () {
    CrossProfile make({
      PkgConfig? pkgConfig,
      Map<String, String> extraEnv = const {},
      String? cmake,
      String? meson,
    }) => CrossProfile(
      providerName: 'arm-gnu',
      targetTriple: 'aarch64-none-linux-gnu',
      cc: 'gcc',
      cxx: 'g++',
      ar: 'ar',
      strip: 'strip',
      targetSysroot: '/sr',
      pkgConfig: pkgConfig,
      extraEnv: extraEnv,
      cmakeToolchainFile: cmake,
      mesonCrossFile: meson,
    );

    test('buildEnv merges extraEnv over pkg-config wiring', () {
      final p = make(
        pkgConfig: const PkgConfig(sysrootDir: '/sr', libdir: ['/l']),
        extraEnv: {'CC': 'oe-gcc', 'PKG_CONFIG_SYSROOT_DIR': '/override'},
      );
      final env = p.buildEnv();
      expect(env['PKG_CONFIG_LIBDIR'], '/l');
      expect(env['CC'], 'oe-gcc');
      // extraEnv wins on conflict.
      expect(env['PKG_CONFIG_SYSROOT_DIR'], '/override');
    });

    test('has*Toolchain flags reflect the file fields', () {
      expect(make().hasCMakeToolchain, isFalse);
      expect(make().hasMesonCross, isFalse);
      final g = make(cmake: '/tc.cmake', meson: '/c.cross');
      expect(g.hasCMakeToolchain, isTrue);
      expect(g.hasMesonCross, isTrue);
    });

    test('withGenerators fills only the toolchain-file fields', () {
      final base = make(extraEnv: {'CC': 'x'});
      final g = base.withGenerators(cmakeToolchainFile: '/tc.cmake');
      expect(g.cmakeToolchainFile, '/tc.cmake');
      expect(g.mesonCrossFile, isNull);
      expect(g.cc, 'gcc');
      expect(g.extraEnv['CC'], 'x');
    });

    test('toString notes sysroot and toolchain files', () {
      final s = make(cmake: '/tc.cmake').toString();
      expect(s, contains('aarch64-none-linux-gnu'));
      expect(s, contains('cmake-tc'));
    });
  });

  group('CrossResolveResult', () {
    const profile = CrossProfile(
      providerName: 'p',
      targetTriple: 't',
      cc: 'cc',
      cxx: 'cxx',
      ar: 'ar',
      strip: 'strip',
      targetSysroot: '/sr',
    );

    test('ok carries the profile and reports ok', () {
      const r = CrossResolveResult.ok(profile);
      expect(r.status, CrossResolveStatus.resolved);
      expect(r.ok, isTrue);
      expect(r.profile, profile);
    });

    test('unavailable / failed carry a message and are not ok', () {
      const u = CrossResolveResult.unavailable('nope');
      expect(u.status, CrossResolveStatus.unavailable);
      expect(u.ok, isFalse);
      expect(u.message, 'nope');

      const f = CrossResolveResult.failed('boom');
      expect(f.status, CrossResolveStatus.failed);
      expect(f.profile, isNull);
    });
  });

  group('CrossGenerator.fromToken', () {
    test('maps cmake/meson and throws on unknown', () {
      expect(CrossGenerator.fromToken('CMAKE'), CrossGenerator.cmake);
      expect(CrossGenerator.fromToken('meson'), CrossGenerator.meson);
      expect(() => CrossGenerator.fromToken('ninja'), throwsArgumentError);
    });
  });
}
