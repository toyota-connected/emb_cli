import 'package:emb_cli/src/cross/cargo_env.dart';
import 'package:emb_cli/src/cross/cross_arch.dart';
import 'package:emb_cli/src/cross/cross_profile.dart';

/// A `cargo` wrapper for code-asset build hooks that run cargo themselves.
///
/// The hook runner replaces a hook's environment, so the cross env a
/// `build: cargo` module gets from [cargoEnv] never reaches a hook that calls
/// plain `cargo` -- it builds for the host and the bundle audit rejects the
/// result. PATH survives, so the env rides in on a wrapper, the same way the
/// `cmake` wrapper carries the toolchain file.
///
/// [linker] is the executable for `CARGO_TARGET_<TRIPLE>_LINKER`: a wrapper
/// that adds `--sysroot` when the profile has one, else the bare compiler.
/// [overlayPkgConfigDirs] are searched before the sysroot, so a library emb
/// built as an augment (e.g. one the crate's build.rs probes) resolves.
/// [realCargo] is the cargo the wrapper execs. [addTarget] installs the
/// target's std through rustup first when it is missing (not offline: it
/// reaches rustup's dist server); a no-op without rustup.
String hookCargoScript({
  required CrossProfile profile,
  required String linker,
  required String realCargo,
  List<String> overlayPkgConfigDirs = const [],
  bool addTarget = true,
}) {
  final triple = rustTriple(profile.targetTriple);
  final upper = triple.replaceAll('-', '_').toUpperCase();
  final pc = profile.pkgConfig;
  final env = <String, String>{
    ...cargoEnv(profile, triple),
    'CARGO_TARGET_${upper}_LINKER': linker,
    if (overlayPkgConfigDirs.isNotEmpty && pc != null) ...{
      'PKG_CONFIG_LIBDIR': [...overlayPkgConfigDirs, ...pc.libdir].join(':'),
      'PKG_CONFIG_SYSROOT_DIR': pc.sysrootDir,
    },
  };

  String q(String s) => "'${s.replaceAll("'", r"'\''")}'";
  final path = profile.extraEnv['PATH'];
  return '#!/bin/sh\n'
      // First-wins over CARGO_TARGET_*_RUSTFLAGS, even when empty.
      'unset RUSTFLAGS CARGO_ENCODED_RUSTFLAGS\n'
      // Yocto SDK: the compiler the linker wrapper execs lives here.
      '${path == null ? '' : 'export PATH=${q(path)}:"\$PATH"\n'}'
      '${env.entries.map((e) => 'export ${e.key}=${q(e.value)}\n').join()}'
      '${addTarget ? _addTarget(triple) : ''}'
      'exec ${q(realCargo)} "\$@"\n';
}

String _addTarget(String triple) =>
    'if command -v rustup >/dev/null 2>&1 &&\n'
    '    ! rustup target list --installed 2>/dev/null | grep -qx $triple; then\n'
    '    rustup target add $triple >&2 || true\n'
    'fi\n';

/// The linker wrapper [hookCargoScript] points cargo at: the profile's
/// compiler with `--sysroot`, since `CARGO_TARGET_*_LINKER` takes a bare path.
/// Null when there is no sysroot to add; use `profile.cc` directly then.
String? hookCargoLinkerScript(CrossProfile profile) {
  if (profile.targetSysroot.isEmpty) return null;
  String q(String s) => "'${s.replaceAll("'", r"'\''")}'";
  final sysroot = q('--sysroot=${profile.targetSysroot}');
  return '#!/bin/sh\nexec ${q(profile.cc)} $sysroot "\$@"\n';
}
