import 'package:emb_cli/src/cross/cross_profile.dart';

/// Which provider sources the toolchain and sysroot(s) for a target.
enum CrossProviderKind {
  /// Downloaded ARM GNU toolchain + a separately-sourced sysroot (a fetched
  /// image `.xz` or a vendor image), prepared via a qemu-static apt chroot.
  /// We emit the CMake/Meson toolchain file.
  armGnu,

  /// A Yocto build-tree `recipe-sysroot` + `recipe-sysroot-native`, located
  /// (not downloaded). We emit the toolchain file; tuning is OE-style.
  yoctoRecipe,

  /// A relocatable `populate_sdk` installer: one `environment-setup-*` script
  /// supplies the compiler, both sysroots, the flags, and the SDK's own
  /// `OEToolchainConfig.cmake` + meson cross file.
  yoctoSdk;

  static CrossProviderKind fromToken(String token) =>
      switch (token.toLowerCase()) {
        'arm-gnu' || 'arm_gnu' || 'armgnu' => CrossProviderKind.armGnu,
        'yocto-recipe' || 'recipe' => CrossProviderKind.yoctoRecipe,
        'yocto-sdk' || 'sdk' || 'esdk' => CrossProviderKind.yoctoSdk,
        _ => throw ArgumentError('unknown cross provider: $token'),
      };

  String get token => switch (this) {
    CrossProviderKind.armGnu => 'arm-gnu',
    CrossProviderKind.yoctoRecipe => 'yocto-recipe',
    CrossProviderKind.yoctoSdk => 'yocto-sdk',
  };
}

/// How the ARM GNU toolchain version is chosen.
enum ToolchainVersionPolicy {
  /// Pinned in the manifest (`toolchain_version`).
  pinned,

  /// Derived from the prepared sysroot's Debian codename — the unoq case,
  /// where the sysroot is probed first and its release picks the toolchain.
  deriveFromSysroot;

  static ToolchainVersionPolicy fromToken(String? token) =>
      switch ((token ?? 'pinned').toLowerCase()) {
        'derive' ||
        'derive-from-sysroot' ||
        'derive_from_sysroot' => ToolchainVersionPolicy.deriveFromSysroot,
        _ => ToolchainVersionPolicy.pinned,
      };
}

/// One source-built library staged into a workspace overlay prefix
/// (libdisplay-info, Vulkan-Headers, …).
///
/// Generalizes the scripts' local deps: the library is built against the
/// resolved [CrossProfile] and installed into an overlay that is prepended to
/// the include/lib/pkg-config search paths, leaving the (possibly shared or
/// read-only) sysroot pristine.
class AugmentLib {
  const AugmentLib({
    required this.pkg,
    required this.minVersion,
    required this.url,
    this.build = CrossGenerator.meson,
    this.staticLink = true,
  });

  factory AugmentLib.fromMap(Map<dynamic, dynamic> map) => AugmentLib(
    pkg: (map['pkg'] ?? '').toString(),
    minVersion: (map['min'] ?? map['min_version'] ?? '0').toString(),
    url: (map['url'] ?? '').toString(),
    build: CrossGenerator.fromToken((map['build'] ?? 'meson').toString()),
    staticLink: (map['static'] ?? true) as bool,
  );

  /// pkg-config module name to probe (and the package to build).
  final String pkg;

  /// Minimum acceptable version; if the sysroot already satisfies it, the
  /// build is skipped.
  final String minVersion;

  /// Source tarball URL for the version to build.
  final String url;

  /// Build system the package uses.
  final CrossGenerator build;

  /// Whether to install only the static archive (so the on-target binary
  /// needs no extra shared object).
  final bool staticLink;
}

/// Where an `arm-gnu` target's sysroot comes from.
enum SysrootProvenance {
  /// Unpacked from a distro image (`.img`/`.img.xz`) — pi / radxa / beagleplay.
  image,

  /// rsync'd from a live, running device over SSH — the unoq pattern, where
  /// the synced rootfs is also what the `derive` toolchain policy reads its
  /// codename from.
  device;

  static SysrootProvenance fromToken(String? token) =>
      switch ((token ?? 'image').toLowerCase()) {
        'device' || 'rsync' || 'ssh' => SysrootProvenance.device,
        _ => SysrootProvenance.image,
      };
}

/// How an `arm-gnu` target's sysroot is acquired.
///
/// Backward compatible with a bare top-level `image_url:` (folded into an
/// [SysrootProvenance.image] spec when no explicit `sysroot:` block is given).
class SysrootSpec {
  const SysrootSpec({
    required this.source,
    this.imageUrl,
    this.deviceHost,
    this.sshPort = 22,
    this.sshOpts,
    this.partition = 2,
  });

  factory SysrootSpec.fromMap(Map<dynamic, dynamic> map) => SysrootSpec(
    source: SysrootProvenance.fromToken(map['source']?.toString()),
    imageUrl: map['image_url']?.toString(),
    deviceHost: (map['host'] ?? map['device_host'])?.toString(),
    sshPort: int.tryParse('${map['ssh_port'] ?? 22}') ?? 22,
    sshOpts: map['ssh_opts']?.toString(),
    partition:
        int.tryParse('${map['partition'] ?? map['rootfs_partition'] ?? 2}') ??
        2,
  );

  final SysrootProvenance source;

  /// Image URL for [SysrootProvenance.image].
  final String? imageUrl;

  /// `user@host` for [SysrootProvenance.device].
  final String? deviceHost;

  /// SSH port for the device rsync.
  final int sshPort;

  /// Extra `ssh`/`rsync -e` options for the device rsync.
  final String? sshOpts;

  /// The 1-based rootfs partition index within an image (Raspberry Pi and
  /// most Debian images put rootfs on `p2`; override with
  /// `sysroot.partition`/`rootfs_partition` for images that differ).
  final int partition;
}

/// The parsed `cross:` block of a target manifest.
///
/// ```yaml
/// cross:
///   provider: yocto-sdk
///   sdk_path: /opt/fsl-imx-wayland/6.6
///   augment:
///     - { pkg: libdisplay-info, min: "0.2.0", build: meson, static: true }
/// ```
class CrossTarget {
  const CrossTarget({
    required this.provider,
    this.targetTriple,
    this.cpuFlags = const [],
    this.toolchainVersion,
    this.toolchainUrl,
    this.versionPolicy = ToolchainVersionPolicy.pinned,
    this.sysroot,
    this.yoctoBuild,
    this.machineTuple,
    this.recipe = 'weston',
    this.sdkPath,
    this.sdkUrl,
    this.sdkEnvSetup,
    this.augment = const [],
  });

  factory CrossTarget.fromMap(Map<dynamic, dynamic> map) {
    final provider = CrossProviderKind.fromToken(
      (map['provider'] ?? '').toString(),
    );
    return CrossTarget(
      provider: provider,
      targetTriple:
          map['triple']?.toString() ?? map['target_triple']?.toString(),
      cpuFlags: _stringList(map['cpu_flags'] ?? map['tuning']),
      toolchainVersion: map['toolchain_version']?.toString(),
      toolchainUrl: map['toolchain_url']?.toString(),
      versionPolicy: ToolchainVersionPolicy.fromToken(
        map['version_policy']?.toString(),
      ),
      sysroot: _parseSysroot(map),
      yoctoBuild: map['yocto_build']?.toString(),
      machineTuple: map['machine_tuple']?.toString(),
      recipe: (map['recipe'] ?? 'weston').toString(),
      sdkPath: map['sdk_path']?.toString(),
      sdkUrl: map['sdk_url']?.toString(),
      sdkEnvSetup: map['sdk_env_setup']?.toString(),
      augment: (map['augment'] as List<dynamic>? ?? const [])
          .whereType<Map<dynamic, dynamic>>()
          .map(AugmentLib.fromMap)
          .toList(),
    );
  }

  final CrossProviderKind provider;

  /// Target triple override (else the provider's default).
  final String? targetTriple;

  /// Alias for [targetTriple] (the manifest key is `triple`).
  String? get triple => targetTriple;

  /// CPU tuning flags, e.g. `['-mcpu=cortex-a55']` or
  /// `['-march=armv8-a+crc+crypto', '-mbranch-protection=standard']`. Stored
  /// as a free-form list, never an enum — the boards span both `-mcpu` and
  /// OE-style `-march` tuning.
  final List<String> cpuFlags;

  // ── arm-gnu ──────────────────────────────────────────────────────────
  final String? toolchainVersion;
  final String? toolchainUrl;
  final ToolchainVersionPolicy versionPolicy;

  /// How the sysroot is acquired (image unpack or device rsync). Always set
  /// for `arm-gnu`; null for the Yocto providers (their sysroot is intrinsic).
  final SysrootSpec? sysroot;

  /// Convenience: the image URL when [sysroot] is image-sourced.
  String? get imageUrl =>
      sysroot?.source == SysrootProvenance.image ? sysroot?.imageUrl : null;

  // ── yocto-recipe ─────────────────────────────────────────────────────
  /// Path to the OE build directory (the dir holding `tmp/work/...`).
  final String? yoctoBuild;

  /// OE machine tuple, e.g. `armv8a-mx8mm-poky-linux`.
  final String? machineTuple;

  /// Recipe whose sysroot to locate (default `weston`, which stages the full
  /// graphics dev sysroot).
  final String recipe;

  // ── yocto-sdk ────────────────────────────────────────────────────────
  /// Path to an already-installed SDK root (the dir containing
  /// `environment-setup-*` and `sysroots/`). Preferred when present.
  final String? sdkPath;

  /// URL of a `populate_sdk` self-extracting installer. When [sdkPath] is
  /// absent (or empty), the installer is downloaded and run non-interactively
  /// into a workspace prefix, then treated like a local install.
  final String? sdkUrl;

  /// Explicit `environment-setup-*` path; if null it is globbed under the
  /// resolved SDK root.
  final String? sdkEnvSetup;

  /// Source-built libraries to stage into the overlay (libdisplay-info, …).
  final List<AugmentLib> augment;

  /// Parse the `sysroot:` block, folding a bare top-level `image_url:` into an
  /// image-sourced spec for backward compatibility. Returns null when neither
  /// is present (the Yocto providers).
  static SysrootSpec? _parseSysroot(Map<dynamic, dynamic> map) {
    final block = map['sysroot'];
    if (block is Map) {
      return SysrootSpec.fromMap(Map<dynamic, dynamic>.from(block));
    }
    final imageUrl = map['image_url']?.toString();
    if (imageUrl != null && imageUrl.isNotEmpty) {
      return SysrootSpec(source: SysrootProvenance.image, imageUrl: imageUrl);
    }
    return null;
  }

  static List<String> _stringList(dynamic v) {
    if (v is List) return v.map((e) => e.toString()).toList();
    if (v is String && v.isNotEmpty) return v.split(RegExp(r'\s+'));
    return const [];
  }
}
