import 'package:emb_cli/src/cross/cross_provider.dart' show CrossProvider;

/// Build-system files a [CrossProfile] can carry (or have emitted for it).
enum CrossGenerator {
  cmake,
  meson;

  static CrossGenerator fromToken(String token) =>
      switch (token.toLowerCase()) {
        'cmake' => CrossGenerator.cmake,
        'meson' => CrossGenerator.meson,
        _ => throw ArgumentError('unknown generator: $token'),
      };
}

/// pkg-config search wiring for a cross sysroot.
///
/// [libdir] feeds `PKG_CONFIG_LIBDIR` (replaces the host search path so host
/// `.pc` files never leak into a cross build); [sysrootDir] feeds
/// `PKG_CONFIG_SYSROOT_DIR` (prefixes `-I`/`-L` paths); [path] feeds the
/// additive `PKG_CONFIG_PATH` (a Yocto SDK populates this rather than
/// replacing the libdir).
class PkgConfig {
  const PkgConfig({
    required this.sysrootDir,
    this.libdir = const [],
    this.path = const [],
  });

  final List<String> libdir;
  final String sysrootDir;
  final List<String> path;

  /// The pkg-config environment variables this configuration sets.
  Map<String, String> toEnv() => {
    if (libdir.isNotEmpty) 'PKG_CONFIG_LIBDIR': libdir.join(':'),
    'PKG_CONFIG_SYSROOT_DIR': sysrootDir,
    if (path.isNotEmpty) 'PKG_CONFIG_PATH': path.join(':'),
  };
}

/// A fully resolved cross-compilation environment: the compiler, the target
/// (and, for Yocto, native) sysroot, tuning flags, pkg-config wiring, and any
/// ready-made build-system toolchain files.
///
/// This is the single currency every [CrossProvider] produces and every
/// downstream stage (emit / configure / build / augment / deploy) consumes, so
/// nothing below the provider needs to know whether the toolchain came from an
/// ARM GNU tarball, a Yocto recipe-sysroot, or a `populate_sdk` installer.
class CrossProfile {
  const CrossProfile({
    required this.providerName,
    required this.targetTriple,
    required this.cc,
    required this.cxx,
    required this.ar,
    required this.strip,
    required this.targetSysroot,
    this.nativeSysroot,
    this.cFlags = const [],
    this.cxxFlags = const [],
    this.ldFlags = const [],
    this.pkgConfig,
    this.cmakeToolchainFile,
    this.mesonCrossFile,
    this.extraEnv = const {},
  });

  /// Provider token that produced this profile (`arm-gnu`, `yocto-recipe`,
  /// `yocto-sdk`) — diagnostics only.
  final String providerName;

  /// Target triple, e.g. `aarch64-none-linux-gnu` or `aarch64-poky-linux`.
  final String targetTriple;

  /// C / C++ compiler. For a Yocto SDK these are the bare binaries; the full
  /// OE invocation (with its embedded `--sysroot` and tuning) is carried in
  /// [extraEnv] as `CC`/`CXX`, which the build stage applies verbatim.
  final String cc;
  final String cxx;
  final String ar;
  final String strip;

  /// The target sysroot (the OE `SDKTARGETSYSROOT` analog).
  final String targetSysroot;

  /// The host/native sysroot. Only Yocto sources have one
  /// (`OECORE_NATIVE_SYSROOT`); the ARM GNU path uses the host's own gcc and
  /// leaves this null.
  final String? nativeSysroot;

  final List<String> cFlags;
  final List<String> cxxFlags;
  final List<String> ldFlags;
  final PkgConfig? pkgConfig;

  /// A ready CMake toolchain file. When non-null the emitter is skipped and
  /// this path is passed straight to `-DCMAKE_TOOLCHAIN_FILE=`. A Yocto SDK
  /// supplies its own (`OEToolchainConfig.cmake`); the ARM GNU and
  /// recipe-sysroot providers leave this null so the emitter writes one from
  /// the rest of the profile.
  final String? cmakeToolchainFile;

  /// A ready Meson cross file — same contract as [cmakeToolchainFile].
  final String? mesonCrossFile;

  /// Extra environment the configure/build must run under. The Yocto SDK
  /// exports a large delta (CC, CXX, CFLAGS, LDFLAGS, SDKTARGETSYSROOT,
  /// OECORE_*, CMAKE_TOOLCHAIN_FILE, …); the ARM GNU path needs only the
  /// pkg-config vars (carried via [pkgConfig]).
  final Map<String, String> extraEnv;

  bool get hasCMakeToolchain => cmakeToolchainFile != null;
  bool get hasMesonCross => mesonCrossFile != null;

  /// The full environment a configure/build invocation should run under,
  /// merging [extraEnv] over the pkg-config wiring. The build stage layers
  /// this on top of the parent process environment.
  Map<String, String> buildEnv() => {
    if (pkgConfig != null) ...pkgConfig!.toEnv(),
    ...extraEnv,
  };

  /// Copy with select build-system files filled in by an emitter.
  CrossProfile withGenerators({
    String? cmakeToolchainFile,
    String? mesonCrossFile,
  }) => CrossProfile(
    providerName: providerName,
    targetTriple: targetTriple,
    cc: cc,
    cxx: cxx,
    ar: ar,
    strip: strip,
    targetSysroot: targetSysroot,
    nativeSysroot: nativeSysroot,
    cFlags: cFlags,
    cxxFlags: cxxFlags,
    ldFlags: ldFlags,
    pkgConfig: pkgConfig,
    cmakeToolchainFile: cmakeToolchainFile ?? this.cmakeToolchainFile,
    mesonCrossFile: mesonCrossFile ?? this.mesonCrossFile,
    extraEnv: extraEnv,
  );

  @override
  String toString() =>
      'CrossProfile($providerName, $targetTriple, sysroot=$targetSysroot'
      '${nativeSysroot != null ? ", native=$nativeSysroot" : ""}'
      '${hasCMakeToolchain ? ", cmake-tc" : ""}'
      '${hasMesonCross ? ", meson-cross" : ""})';
}

/// Outcome of a [CrossProvider.resolve] call. Mirrors the `EngineFetchResult`
/// status pattern: a typed status plus the payload (or a diagnostic message).
enum CrossResolveStatus {
  /// A usable [CrossProfile] was produced.
  resolved,

  /// The provider's inputs aren't present (no SDK at the path, no built
  /// recipe-sysroot, no published toolchain) — recoverable with operator
  /// action.
  unavailable,

  /// Resolution started but a step failed (download, extract, chroot, env
  /// source).
  failed,
}

/// Result of resolving a cross environment.
class CrossResolveResult {
  const CrossResolveResult({required this.status, this.profile, this.message});

  /// Convenience constructor for the success case.
  const CrossResolveResult.ok(CrossProfile this.profile)
    : status = CrossResolveStatus.resolved,
      message = null;

  /// Convenience constructor for [CrossResolveStatus.unavailable].
  const CrossResolveResult.unavailable(String this.message)
    : status = CrossResolveStatus.unavailable,
      profile = null;

  /// Convenience constructor for [CrossResolveStatus.failed].
  const CrossResolveResult.failed(String this.message)
    : status = CrossResolveStatus.failed,
      profile = null;

  final CrossResolveStatus status;
  final CrossProfile? profile;
  final String? message;

  bool get ok => status == CrossResolveStatus.resolved;
}
