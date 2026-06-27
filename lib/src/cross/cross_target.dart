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
    this.defines = const {},
    this.host = false,
  });

  factory AugmentLib.fromMap(Map<dynamic, dynamic> map) => AugmentLib(
    pkg: (map['pkg'] ?? '').toString(),
    minVersion: (map['min'] ?? map['min_version'] ?? '0').toString(),
    url: (map['url'] ?? '').toString(),
    build: CrossGenerator.fromToken((map['build'] ?? 'meson').toString()),
    staticLink: (map['static'] ?? true) as bool,
    defines:
        (map['defines'] as Map?)?.map(
          (k, v) => MapEntry(k.toString(), v.toString()),
        ) ??
        const <String, String>{},
    host: (map['host'] ?? false) as bool,
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

  /// Extra `-D<key>=<value>` options passed to the package's configure step:
  /// CMake cache entries (e.g. `BLEND2D_STATIC=ON`) or, for meson packages,
  /// project options (e.g. `some_feature=enabled`) — both use `-Dkey=value`.
  final Map<String, String> defines;

  /// When true, build this package with the **host** toolchain and install its
  /// executable(s) onto the cross build's PATH, rather than cross-compiling a
  /// library into the sysroot. For codegen/build tools that run on the build
  /// machine during the target build (e.g. a `wayland-cxx-scanner` resolved via
  /// CMake `find_program`). `static` / `min` / pkg-config probing do not apply;
  /// only `build: cmake` is supported for host tools.
  final bool host;
}

/// The `package:` block of a cross manifest — how `emb cross --deb`/`--flatpak`
/// turns a built binary (or assembled bundle) into a distributable package. All
/// fields are optional; the command fills in sensible defaults (name from the
/// manifest id, arch from the triple).
class PackageSpec {
  const PackageSpec({
    this.name,
    this.version = '0.0.0',
    this.maintainer = 'emb <emb@localhost>',
    this.description,
    this.section = 'misc',
    this.priority = 'optional',
    this.bin,
    this.installDir = '/usr/bin',
    this.depends = const [],
    this.autoDepends = true,
    this.files = const {},
    this.flatpak,
  });

  factory PackageSpec.fromMap(Map<dynamic, dynamic> map) => PackageSpec(
    name: map['name']?.toString(),
    version: (map['version'] ?? '0.0.0').toString(),
    maintainer: (map['maintainer'] ?? 'emb <emb@localhost>').toString(),
    description: map['description']?.toString(),
    section: (map['section'] ?? 'misc').toString(),
    priority: (map['priority'] ?? 'optional').toString(),
    bin: map['bin']?.toString(),
    installDir: (map['install_dir'] ?? '/usr/bin').toString(),
    depends: (map['depends'] as List<dynamic>? ?? const [])
        .map((e) => e.toString())
        .toList(),
    autoDepends: (map['auto_depends'] ?? true) as bool,
    files: (map['files'] as Map<dynamic, dynamic>? ?? const {}).map(
      (k, v) => MapEntry(k.toString(), v.toString()),
    ),
    flatpak: map['flatpak'] is Map
        ? FlatpakPackageSpec.fromMap(
            Map<dynamic, dynamic>.from(map['flatpak'] as Map),
          )
        : null,
  );

  /// Package name; defaults to the manifest id when unset.
  final String? name;
  final String version;
  final String maintainer;

  /// Synopsis; a generated default is used when unset.
  final String? description;
  final String section;
  final String priority;

  /// Binary to package, relative to a backend's build dir (e.g.
  /// `shell/homescreen`). When unset the command auto-finds the ELF executable.
  final String? bin;

  /// Absolute install directory on the target (the binary keeps its basename).
  final String installDir;

  /// Explicit `Depends`, merged with the auto-derived set.
  final List<String> depends;

  /// Derive `Depends` from the binary's `DT_NEEDED` libraries.
  final bool autoDepends;

  /// Extra files to include in the package, as `<host source>: <destination>`.
  /// The source is resolved relative to the manifest directory; the
  /// destination is an absolute target path for a `.deb` (e.g.
  /// `/etc/app/config.toml`) or a path under the `/app` prefix for a
  /// `.flatpak`. Lets a manifest ship config, icons, udev rules, etc. alongside
  /// the binary.
  final Map<String, String> files;

  /// Flatpak-specific manifest fields (app id, runtime, sandbox perms). Only
  /// consulted by `--flatpak`; `--deb` ignores it.
  final FlatpakPackageSpec? flatpak;
}

/// The `package.flatpak:` sub-block — the flatpak manifest knobs `--flatpak`
/// needs beyond the shared [PackageSpec] fields.
class FlatpakPackageSpec {
  const FlatpakPackageSpec({
    this.appId,
    this.branch = 'stable',
    this.runtime = 'org.freedesktop.Platform',
    this.runtimeVersion = '23.08',
    this.sdk = 'org.freedesktop.Sdk',
    this.finishArgs = const [],
    this.icon,
    this.categories = const ['Utility'],
  });

  factory FlatpakPackageSpec.fromMap(Map<dynamic, dynamic> map) =>
      FlatpakPackageSpec(
        appId: (map['app_id'] ?? map['id'])?.toString(),
        branch: (map['branch'] ?? 'stable').toString(),
        runtime: (map['runtime'] ?? 'org.freedesktop.Platform').toString(),
        runtimeVersion: (map['runtime_version'] ?? '23.08').toString(),
        sdk: (map['sdk'] ?? 'org.freedesktop.Sdk').toString(),
        finishArgs: (map['finish_args'] as List<dynamic>? ?? const [])
            .map((e) => e.toString())
            .toList(),
        icon: map['icon']?.toString(),
        categories: (map['categories'] as List<dynamic>? ?? const ['Utility'])
            .map((e) => e.toString())
            .toList(),
      );

  /// Reverse-DNS app id, e.g. `com.toyota.ivi.Homescreen`. Required to build a
  /// flatpak; the command errors if it is unset.
  final String? appId;
  final String branch;
  final String runtime;
  final String runtimeVersion;
  final String sdk;

  /// Sandbox `finish-args`; empty falls back to the packager's Wayland default.
  final List<String> finishArgs;

  /// Icon path relative to the manifest directory (PNG/SVG). Optional.
  final String? icon;

  /// `.desktop` `Categories`.
  final List<String> categories;
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
    this.devPackages = const [],
    this.symlinks = const {},
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
    devPackages: (map['dev_packages'] as List<dynamic>? ?? const [])
        .map((e) => e.toString())
        .toList(),
    symlinks: (map['symlinks'] as Map<dynamic, dynamic>? ?? const {}).map(
      (k, v) => MapEntry(k.toString(), v.toString()),
    ),
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

  /// `-dev` Debian package **names** to layer into the sysroot root-free. emb
  /// resolves their dependency closure against the sysroot's own apt sources,
  /// then downloads each `.deb` and `dpkg-deb -x`'s it in — no apt, no chroot,
  /// no root. List only the top-level packages (e.g. `libdrm-dev`,
  /// `libegl-dev`); deps are pulled in automatically.
  final List<String> devPackages;

  /// Symlinks to create inside the sysroot after staging, as
  /// `<link-path-in-sysroot>: <target>` (the target is used verbatim, so a
  /// sibling-relative target stays valid under a relocated sysroot). For an
  /// image whose packages omit a header tree another package ships elsewhere —
  /// e.g. `usr/include/drm: libdrm` points `<drm/*.h>` at libdrm-dev's
  /// `usr/include/libdrm/` when the kernel `linux-libc-dev` lacks `drm/`.
  /// Skipped when something already exists at the link path.
  final Map<String, String> symlinks;
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
    this.generator = CrossGenerator.cmake,
    this.backends = const {},
    this.package,
    this.defines = const {},
    this.cmakeArgs = const [],
    this.hostTools = false,
    this.hostDevPackages = const [],
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
      generator: CrossGenerator.fromToken(
        (map['generator'] ?? 'cmake').toString(),
      ),
      backends: _parseBackends(map['backends']),
      package: map['package'] is Map
          ? PackageSpec.fromMap(
              Map<dynamic, dynamic>.from(map['package'] as Map),
            )
          : null,
      defines: _parseDefines(map['defines']),
      cmakeArgs: _stringList(map['cmake_args']),
      hostTools:
          (map['host_build_tools'] ?? map['host_cmake'] ?? false) == true,
      hostDevPackages: _stringList(map['host_dev_packages']),
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

  /// Build system to configure the embedder with (default CMake).
  final CrossGenerator generator;

  /// Per-backend build matrix: backend name → the build-system `-D` defines it
  /// implies, e.g. `{wayland-egl: {BUILD_BACKEND_WAYLAND_EGL: ON}}`. Each is
  /// built into its own `build-<backend>` dir by `emb cross --build`.
  final Map<String, Map<String, String>> backends;

  /// Optional `.deb` packaging config for `emb cross --deb`.
  final PackageSpec? package;

  /// Shared build-system `-D` defines applied to **every** build (each backend
  /// and the no-backend build). A per-backend define of the same name wins.
  final Map<String, String> defines;

  /// Raw extra arguments passed verbatim to the CMake configure command (e.g.
  /// `[-Wno-dev, --fresh]`). CMake-only; ignored for Meson projects.
  final List<String> cmakeArgs;

  /// Use the **host's** build tool — `cmake` for a CMake project, `meson` for a
  /// Meson one — resolved from the host `PATH`, instead of the one on the
  /// SDK/profile build env. Some OE SDKs pin an old `nativesdk-cmake`/`-meson`
  /// (e.g. AGL ships cmake 3.16.5) below what a project requires; the host tool
  /// runs with the same OE env + toolchain/cross file, just a newer binary.
  /// (Manifest key `host_build_tools`; `host_cmake` is accepted as an alias.)
  final bool hostTools;

  /// Host (build-machine) `-dev` package names to install into the cross build
  /// environment — the host-side parallel of `sysroot.dev_packages`. Needed
  /// when a `host: true` augment (a build-machine codegen tool) has host build
  /// deps, e.g. `libpugixml-dev` for the host wayland-cxx-scanner. Baked into
  /// the cross image by the Dockerfile emit so the build host can compile the
  /// host tool. (Manifest key `host_dev_packages`.)
  final List<String> hostDevPackages;

  /// Parse the `backends:` block (backend name → `{define: value}` map).
  static Map<String, Map<String, String>> _parseBackends(Object? value) {
    if (value is! Map) return const {};
    final out = <String, Map<String, String>>{};
    value.forEach((name, defines) {
      if (defines is Map) {
        out[name.toString()] = {
          for (final e in defines.entries) e.key.toString(): e.value.toString(),
        };
      }
    });
    return out;
  }

  /// Parse the flat `defines:` block (`{name: value}` → `-Dname=value`).
  static Map<String, String> _parseDefines(Object? value) {
    if (value is! Map) return const {};
    return {
      for (final e in value.entries) e.key.toString(): e.value.toString(),
    };
  }

  /// Parse the `sysroot:` block, folding a bare top-level `image_url:` into an
  /// image-sourced spec for backward compatibility. Returns null when neither
  /// is present (the Yocto providers).
  static SysrootSpec? _parseSysroot(Map<dynamic, dynamic> map) {
    final block = map['sysroot'];
    final topImageUrl = map['image_url']?.toString();
    if (block is Map) {
      // A top-level `image_url:` is a convenience alias; fold it in as the
      // default when the `sysroot:` block doesn't carry its own.
      final merged = Map<dynamic, dynamic>.from(block);
      if ((merged['image_url']?.toString() ?? '').isEmpty &&
          topImageUrl != null &&
          topImageUrl.isNotEmpty) {
        merged['image_url'] = topImageUrl;
      }
      return SysrootSpec.fromMap(merged);
    }
    final imageUrl = topImageUrl;
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
