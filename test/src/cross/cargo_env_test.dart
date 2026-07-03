import 'package:emb_cli/src/cross/cargo_env.dart';
import 'package:emb_cli/src/cross/cross_profile.dart';
import 'package:test/test.dart';

void main() {
  CrossProfile profile({
    List<String> cFlags = const ['-mcpu=cortex-a76'],
    List<String> ldFlags = const [],
    PkgConfig? pkgConfig,
  }) => CrossProfile(
    providerName: 'arm-gnu',
    targetTriple: 'aarch64-none-linux-gnu',
    cc: '/tc/bin/aarch64-none-linux-gnu-gcc',
    cxx: '/tc/bin/aarch64-none-linux-gnu-g++',
    ar: '/tc/bin/aarch64-none-linux-gnu-ar',
    strip: '/tc/bin/aarch64-none-linux-gnu-strip',
    targetSysroot: '/sysroot',
    cFlags: cFlags,
    ldFlags: ldFlags,
    pkgConfig: pkgConfig,
  );

  const rust = 'aarch64-unknown-linux-gnu';

  test('emits target-suffixed CC/AR/LINKER from the profile', () {
    final env = cargoEnv(profile(), rust);
    expect(
      env['CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_LINKER'],
      '/tc/bin/aarch64-none-linux-gnu-gcc',
    );
    expect(env['CC_aarch64_unknown_linux_gnu'], contains('-gcc'));
    expect(env['CXX_aarch64_unknown_linux_gnu'], contains('-g++'));
    expect(env['AR_aarch64_unknown_linux_gnu'], contains('-ar'));
    // No bare CC/CFLAGS that would poison host build scripts.
    expect(env.containsKey('CC'), isFalse);
    expect(env.containsKey('CFLAGS'), isFalse);
  });

  test('carries the sysroot + cpu tuning into target CFLAGS and bindgen', () {
    final env = cargoEnv(profile(), rust);
    // cc-rs C compilation must see the sysroot, not just the cpu tuning, plus
    // the reproducibility prefix-map flags.
    expect(
      env['CFLAGS_aarch64_unknown_linux_gnu'],
      startsWith('--sysroot=/sysroot -mcpu=cortex-a76'),
    );
    expect(
      env['CFLAGS_aarch64_unknown_linux_gnu'],
      contains('-ffile-prefix-map=/sysroot=/emb/sysroot'),
    );
    expect(
      env['BINDGEN_EXTRA_CLANG_ARGS'],
      startsWith('--sysroot=/sysroot -mcpu=cortex-a76'),
    );
  });

  test('enables cross pkg-config and merges the sysroot wiring', () {
    final env = cargoEnv(
      profile(
        pkgConfig: const PkgConfig(
          sysrootDir: '/sysroot',
          libdir: ['/sysroot/usr/lib/pkgconfig'],
        ),
      ),
      rust,
    );
    expect(env['PKG_CONFIG_ALLOW_CROSS'], '1');
    expect(env['PKG_CONFIG_SYSROOT_DIR'], '/sysroot');
    expect(env['PKG_CONFIG_LIBDIR'], '/sysroot/usr/lib/pkgconfig');
  });

  test(
    'rustc link args carry the sysroot + the C search paths, then ldFlags',
    () {
      // The rustc link step runs through gcc, so it must receive the same
      // --sysroot and crt/libc search paths the cmake/meson link uses — which
      // arm-gnu keeps in cFlags, with ldFlags empty. Without this the linker
      // cannot find crt1.o / -lc.
      final env = cargoEnv(profile(), rust);
      final rf = env['CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_RUSTFLAGS']!;
      expect(
        rf,
        startsWith(
          '-C link-arg=--sysroot=/sysroot -C link-arg=-mcpu=cortex-a76',
        ),
      );
      // The Rust half is canonicalized with --remap-path-prefix, not the
      // gcc-style prefix-map flags.
      expect(rf, contains('--remap-path-prefix=/sysroot=/emb/sysroot'));

      // A realistic Debian-multiarch arm-gnu flag set: the -B/-L crt/libc paths
      // must reach the linker as link-args.
      final ma = cargoEnv(
        profile(
          cFlags: const [
            '-mcpu=cortex-a76',
            '-B/sysroot/usr/lib/aarch64-linux-gnu',
            '-L/sysroot/usr/lib/aarch64-linux-gnu',
            '-Wl,-rpath-link,/sysroot/usr/lib/aarch64-linux-gnu',
          ],
        ),
        rust,
      );
      final rustflags = ma['CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_RUSTFLAGS']!;
      expect(rustflags, contains('-C link-arg=--sysroot=/sysroot'));
      expect(
        rustflags,
        contains('-C link-arg=-B/sysroot/usr/lib/aarch64-linux-gnu'),
      );
      expect(
        rustflags,
        contains('-C link-arg=-L/sysroot/usr/lib/aarch64-linux-gnu'),
      );

      // Provider ldFlags (when set, e.g. Yocto) are appended after cFlags —
      // among the link args, ahead of the trailing remap-path-prefix flags.
      final withLd = cargoEnv(profile(ldFlags: [r'-Wl,-rpath,$ORIGIN']), rust);
      expect(
        withLd['CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_RUSTFLAGS'],
        contains(r'-C link-arg=-Wl,-rpath,$ORIGIN'),
      );
    },
  );

  test('omits the sysroot flags when the profile has no sysroot (native)', () {
    final env = cargoEnv(
      const CrossProfile(
        providerName: 'local',
        targetTriple: 'x86_64-linux-gnu',
        cc: '/usr/bin/gcc',
        cxx: '/usr/bin/g++',
        ar: '/usr/bin/ar',
        strip: '/usr/bin/strip',
        targetSysroot: '',
      ),
      'x86_64-unknown-linux-gnu',
    );
    expect(env['BINDGEN_EXTRA_CLANG_ARGS'], isNot(contains('--sysroot')));
    expect(
      env.containsKey('CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_RUSTFLAGS'),
      isFalse,
    );
  });
}
