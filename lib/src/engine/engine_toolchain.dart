/// Engine toolchain profile: the axes that determine which engine artifact is
/// produced or consumed.
library;

/// Target operating system for an engine artifact.
enum TargetOs {
  linux,
  android;

  /// The token used in an artifact key.
  String get token => name;
}

/// Target C library / ABI. This is the axis that forks the engine binary
/// (a glibc and a musl engine are distinct artifacts).
enum Libc {
  glibc,
  musl,
  bionic;

  /// The token used in an artifact key.
  String get token => name;

  /// Parse a libc token (`glibc`/`gnu`, `musl`, `bionic`/`android`).
  static Libc fromToken(String value) => switch (value.toLowerCase().trim()) {
    'glibc' || 'gnu' => Libc.glibc,
    'musl' => Libc.musl,
    'bionic' || 'android' => Libc.bionic,
    _ => throw ArgumentError('unknown libc token: $value'),
  };
}

/// A resolved engine toolchain profile.
///
/// The engine is always built with clang ([compilerId] defaults to the engine's
/// own clang); GCC lives only on the embedder/userland side. [libc] and
/// [sysrootId] select the target ABI.
class ToolchainProfile {
  const ToolchainProfile({
    required this.os,
    required this.libc,
    this.sysrootId,
    this.compilerId = engineClang,
  });

  /// The native Linux/glibc profile — the only one wired in milestone 1.
  static const ToolchainProfile linuxGlibc = ToolchainProfile(
    os: TargetOs.linux,
    libc: Libc.glibc,
  );

  /// The default (and, for now, only) engine compiler identity.
  static const String engineClang = 'engine-clang';

  final TargetOs os;
  final Libc libc;

  /// Distinguishes musl flavours (`poky` / `alpine` / `debian`) until they are
  /// proven interchangeable; null for the single-sysroot glibc case.
  final String? sysrootId;

  /// The engine compiler identity. Only the engine's own clang for now; an
  /// external/meta-clang override would set a different id (reserved).
  final String compilerId;

  /// The content-addressed store key for an engine artifact under this profile:
  /// `<commit>-<os>-<arch>-<mode>-<libc>[-<sysrootId>][-<compilerId>]`.
  ///
  /// The userland toolchain (gcc vs clang) is deliberately absent — the C ABI /
  /// libc contract makes it interop-neutral (verified by the ABI gate,).
  String storeKey({
    required String commit,
    required String arch,
    required String mode,
  }) {
    final parts = <String>[commit, os.token, arch, mode, libc.token];
    if (sysrootId != null) parts.add(sysrootId!);
    if (compilerId != engineClang) parts.add(compilerId);
    return parts.join('-');
  }
}
