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

  test('carries cpu tuning into the target CFLAGS and bindgen args', () {
    final env = cargoEnv(profile(), rust);
    expect(env['CFLAGS_aarch64_unknown_linux_gnu'], '-mcpu=cortex-a76');
    expect(
      env['BINDGEN_EXTRA_CLANG_ARGS'],
      '--sysroot=/sysroot -mcpu=cortex-a76',
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

  test('maps ldFlags to target-scoped rustc link args only when present', () {
    expect(
      cargoEnv(
        profile(),
        rust,
      ).containsKey('CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_RUSTFLAGS'),
      isFalse,
    );
    final env = cargoEnv(profile(ldFlags: [r'-Wl,-rpath,$ORIGIN']), rust);
    expect(
      env['CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_RUSTFLAGS'],
      r'-C link-arg=-Wl,-rpath,$ORIGIN',
    );
  });
}
