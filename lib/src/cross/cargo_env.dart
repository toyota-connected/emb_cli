import 'package:emb_cli/src/cross/cross_profile.dart';

/// The Cargo / cc-rs environment for cross-compiling a Rust module for
/// [rustTriple] using the C toolchain in [profile]. The caller layers this over
/// the parent process environment.
///
/// Uses **target-suffixed** variables (`CC_<triple>`,
/// `CARGO_TARGET_<TRIPLE>_LINKER`, `CFLAGS_<triple>`, …) rather than the bare
/// `CC`/`CFLAGS`, so a crate's *host* build scripts (`build.rs`, proc-macros)
/// still compile with the host toolchain while the *target* artifacts use the
/// cross compiler.
///
/// The compiler is taken from [profile] as a complete cross `gcc` path — the
/// arm-gnu (and native `local`) shape. A Yocto SDK carries a bare compiler plus
/// its real invocation in `extraEnv`, which is not wired here; cargo modules
/// target the arm-gnu providers for now.
Map<String, String> cargoEnv(CrossProfile profile, String rustTriple) {
  final lower = rustTriple.replaceAll('-', '_');
  final upper = lower.toUpperCase();

  // rustc drives both the cc-rs C compilation and the final link through the C
  // toolchain (`profile.cc`), so those steps need the same `--sysroot` and
  // search-path flags the cmake/meson paths hand the compiler. The arm-gnu
  // provider carries its crt/libc search paths — the Debian multiarch
  // `-B`/`-L`/`-I` and `-Wl,-rpath-link` — in `cFlags` and leaves `ldFlags`
  // empty, so the old code (link args from `ldFlags` only, no `--sysroot` on
  // `CFLAGS`) dropped every one of them and each cdylib failed to link with
  // `cannot find crt1.o` / `cannot find -lc`. Source the compile flags and the
  // rustc link args from the same set the C build uses: `--sysroot` + `cFlags`
  // (+ `ldFlags` for providers that populate it).
  final sysrootArg = profile.targetSysroot.isNotEmpty
      ? ['--sysroot=${profile.targetSysroot}']
      : const <String>[];
  final cflags = [...sysrootArg, ...profile.cFlags].join(' ');
  final cxxflags = [...sysrootArg, ...profile.cxxFlags].join(' ');
  final linkArgs = [...sysrootArg, ...profile.cFlags, ...profile.ldFlags];

  return {
    // Linker driver + cc-rs compiler selection, target-scoped.
    'CARGO_TARGET_${upper}_LINKER': profile.cc,
    'CC_$lower': profile.cc,
    'CXX_$lower': profile.cxx,
    'AR_$lower': profile.ar,
    if (cflags.isNotEmpty) 'CFLAGS_$lower': cflags,
    if (cxxflags.isNotEmpty) 'CXXFLAGS_$lower': cxxflags,
    // Target-scoped rustc link args — kept off the global RUSTFLAGS so host
    // build scripts are unaffected. Each flag is wrapped as a `link-arg` so
    // rustc forwards it verbatim to the `gcc` linker driver.
    if (linkArgs.isNotEmpty)
      'CARGO_TARGET_${upper}_RUSTFLAGS': linkArgs
          .map((f) => '-C link-arg=$f')
          .join(' '),
    // pkg-config: permit cross probing and carry the sysroot wiring.
    'PKG_CONFIG_ALLOW_CROSS': '1',
    ...?profile.pkgConfig?.toEnv(),
    // bindgen (for `-sys` crates) needs the sysroot + tuning on its clang args.
    'BINDGEN_EXTRA_CLANG_ARGS': [...sysrootArg, ...profile.cFlags].join(' '),
  };
}
