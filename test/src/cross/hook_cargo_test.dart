import 'package:emb_cli/src/cross/cross_profile.dart';
import 'package:emb_cli/src/cross/hook_cargo.dart';
import 'package:test/test.dart';

void main() {
  CrossProfile profile({
    String sysroot = '/sysroot',
    Map<String, String> extraEnv = const {},
  }) => CrossProfile(
    providerName: 'arm-gnu',
    targetTriple: 'aarch64-none-linux-gnu',
    cc: '/tc/bin/aarch64-none-linux-gnu-gcc',
    cxx: '/tc/bin/aarch64-none-linux-gnu-g++',
    ar: '/tc/bin/aarch64-none-linux-gnu-ar',
    strip: '/tc/bin/aarch64-none-linux-gnu-strip',
    targetSysroot: sysroot,
    cFlags: const ['-mcpu=cortex-a76'],
    pkgConfig: PkgConfig(
      sysrootDir: sysroot,
      libdir: ['$sysroot/usr/lib/aarch64-linux-gnu/pkgconfig'],
    ),
    extraEnv: extraEnv,
  );

  String script({
    CrossProfile? p,
    List<String> overlay = const [],
    bool addTarget = true,
  }) => hookCargoScript(
    profile: p ?? profile(),
    linker: '/hook/emb-hook-cargo-linker',
    realCargo: '/home/u/.cargo/bin/cargo',
    overlayPkgConfigDirs: overlay,
    addTarget: addTarget,
  );

  test('exports the module cargo env and execs the real cargo', () {
    final s = script();
    expect(s, startsWith('#!/bin/sh\n'));
    expect(s, contains('unset RUSTFLAGS CARGO_ENCODED_RUSTFLAGS\n'));
    const linker = 'CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_LINKER';
    expect(s, contains("export $linker='/hook/emb-hook-cargo-linker'\n"));
    expect(s, contains('export CC_aarch64_unknown_linux_gnu='));
    expect(s, contains("export PKG_CONFIG_SYSROOT_DIR='/sysroot'\n"));
    expect(s, contains('BINDGEN_EXTRA_CLANG_ARGS='));
    expect(s, endsWith("exec '/home/u/.cargo/bin/cargo' \"\$@\"\n"));
  });

  test('searches the overlay before the sysroot', () {
    final s = script(overlay: ['/ov/usr/lib/pkgconfig']);
    const sysrootPc = '/sysroot/usr/lib/aarch64-linux-gnu/pkgconfig';
    expect(
      s,
      contains("export PKG_CONFIG_LIBDIR='/ov/usr/lib/pkgconfig:$sysrootPc'\n"),
    );
  });

  test('adds the rustup target unless offline', () {
    expect(script(), contains('rustup target add aarch64-unknown-linux-gnu'));
    expect(script(addTarget: false), isNot(contains('rustup')));
  });

  test('prepends a Yocto SDK PATH', () {
    final s = script(p: profile(extraEnv: {'PATH': '/sdk/bin'}));
    expect(s, contains("export PATH='/sdk/bin':\"\$PATH\"\n"));
  });

  test('linker wrapper adds --sysroot, or is not needed', () {
    const cc = "'/tc/bin/aarch64-none-linux-gnu-gcc'";
    expect(
      hookCargoLinkerScript(profile()),
      "#!/bin/sh\nexec $cc '--sysroot=/sysroot' \"\$@\"\n",
    );
    expect(hookCargoLinkerScript(profile(sysroot: '')), isNull);
  });
}
