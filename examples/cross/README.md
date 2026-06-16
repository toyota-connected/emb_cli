# Cross-target manifest examples

One manifest per `ivi-homescreen/scripts/build_*.sh`, plus both Yocto-SDK
locations. Each exercises the `cross:` block parsed by `CrossTarget.fromMap`
(`lib/src/cross/cross_target.dart`).

`pi5.emb.yaml` is **validated end-to-end** (`--build` + `--deb` produce an
aarch64 binary and an installable `.deb`) and carries the full
`sysroot.dev_packages` / `backends` / `package` config. The rest are **parse /
plan validated** (`--dry-run`); their values are lifted verbatim from the
scripts.

| manifest | script | provider | toolchain / sysroot | tuning | augment |
|---|---|---|---|---|---|
| `pi5.emb.yaml` ✅ | `build_pi.sh --target pi5` | `arm-gnu` | pinned 12.3.rel1 / raspios bookworm **image** | `-mcpu=cortex-a76` | libdisplay-info |
| `unoq.emb.yaml` | `build_unoq.sh` | `arm-gnu` | **derive** / **device rsync** | `-mcpu=cortex-a53` | libdisplay-info |
| `radxa_zero3.emb.yaml` | `build_radxa_zero3.sh` | `arm-gnu` | pinned 12.3.rel1 / radxa bookworm **image** | `-mcpu=cortex-a55` | libdisplay-info + vulkan-headers |
| `beagleplay.emb.yaml` | `build_beagleplay.sh` (k3) | `arm-gnu` | pinned 15.2.rel1 / beagleplay trixie **image** | `-mcpu=cortex-a53` | none (trixie new enough) |
| `nitrogen8mm.emb.yaml` | `build_nitrogen8mm.sh` | `yocto-recipe` | located weston recipe-sysroot | OE `-march` | libdisplay-info |
| `agl_sdk_local.emb.yaml` | (AGL SDK, installed) | `yocto-sdk` | `sdk_path` → `environment-setup-aarch64-agl-linux` | from `CFLAGS` | none |
| `agl_sdk_url.emb.yaml` | (AGL SDK, downloaded) | `yocto-sdk` | `sdk_url` → install → `environment-setup-aarch64-agl-linux` | from `CFLAGS` | none |

The files above are one board per manifest. **`raspberry-pi-family.emb.yaml`**
shows the alternative: several boards in *one* manifest via `cross.targets`
(rpi4/rpi5/rpi-zero-2w/radxa-zero3), selected with `--target`. Shared config
lives at the `cross:` level; each target overrides only its image + `-mcpu`.

```sh
emb cross raspberry-pi-family.emb.yaml --list-targets
emb cross raspberry-pi-family.emb.yaml --target rpi5 --build --deb
```

**`all-backends.emb.yaml`** builds every ivi-homescreen backend
(wayland-egl/-vulkan, drm-kms-egl/-vulkan, software, headless-egl) natively via
the built-in `local` target, using the `cross.backends` matrix + a shared
`cross.defines`. Copy it next to the ivi-homescreen source (`emb cross <file>`
builds the file's parent dir) and:

```sh
emb cross all-backends.emb.yaml --target local --build
```

## Validated workflow (pi5)

Run from the `ivi-homescreen` package dir (where its `emb.yaml` lives). `emb
cross` accepts a package dir or an explicit manifest file.

```sh
# 1. Inspect the plan — no download / mount / ssh side effects.
emb cross . --dry-run

# 2. Resolve toolchain + sysroot (root-free) and build each cross.backends
#    entry. Augment libs (libdisplay-info 0.2.0) are built and staged first.
emb cross . --build

# 3. Build, then package each backend binary into a root-free .deb. Depends is
#    auto-derived from the binary's DT_NEEDED. Output: cross-build-<triple>/dist.
emb cross . --build --deb

# 4. Reclaim disk. --clean drops the build + overlay dirs (keeps the multi-GB
#    toolchain + sysroot); --clean-all also removes the downloaded/extracted
#    toolchain + sysroot and the apt/deb caches.
emb cross . --clean
emb cross . --clean-all
```

What lands where, under `<workspace>/.config/flutter_workspace/`:

- `cross-<triple>/` — downloaded + extracted toolchain, the assembled sysroot,
  and the resolver's `debs/` + apt cache.
- `cross-build-<triple>/build-<backend>/` — one CMake/Meson build tree per
  backend; `cross-build-<triple>/dist/` — the generated `.deb`(s).
- `overlay-<triple>/`, `overlay-src/` — augment build prefix + sources.

## Sysroot provenance (arm-gnu)

The `cross.sysroot` block selects how the sysroot is acquired:

- `source: image` (+ `image_url`) — download + loop-mount + rsync. A bare
  top-level `image_url:` is accepted as shorthand and folds into this.
- `source: device` (+ `host`, `ssh_port`, `ssh_opts`) — rsync the rootfs from a
  live board. `ArmGnuCrossProvider` probes for rsync + passwordless sudo, then
  mirrors via `--rsync-path='sudo rsync'` when available. This is what makes
  the unoq **derive** policy work: the synced rootfs is what
  `_detectCodename` reads to pick the toolchain version.

## Yocto SDK location (yocto-sdk) — Automotive Grade Linux

The two SDK examples use AGL, which is its own Yocto-based distro: the triple is
`aarch64-agl-linux` (set it explicitly — the OE env only derives
`aarch64-linux`), the env script is `environment-setup-aarch64-agl-linux`, and
the installer is `poky-agl-glibc-x86_64-agl-demo-platform-crosssdk-<machine>-toolchain-<version>.sh`
(default install dir `/opt/agl-sdk/<version>-<machine>`). SDKs are published
under `https://download.automotivelinux.org/AGL/release/<codename>/...`.

AGL codename ↔ UCB version: icefish=9, jellyfish=10, koi=11, lamprey=12,
**marlin=13** (the release that integrated Toyota's embedded Flutter solution —
the on-point one for ivi-homescreen), needlefish=14, octopus=15, pike=16,
Terrific Trout (2025), Ultimate Unagi (latest, 2026).

`YoctoSdkCrossProvider` resolves the SDK from, in order:

1. `sdk_env_setup` — explicit `environment-setup-*` path.
2. `sdk_path` — an installed AGL SDK root (e.g. `/opt/agl-sdk/13.0.0-aarch64`).
3. `sdk_url` — the AGL installer; downloaded and run non-interactively
   (`sh <installer> -y -d <workspace-prefix>`), then treated like a local
   install. Re-runs are no-ops once the prefix is populated.

In all three the script is sourced in a clean shell and the env read back, so
`CC`/`CXX`/`CFLAGS`/`SDKTARGETSYSROOT`/`OECORE_NATIVE_SYSROOT`/
`CMAKE_TOOLCHAIN_FILE` flow through verbatim.

## Run the test

```sh
dart test test/src/cross/cross_target_examples_test.dart
```

The test deep-converts each YAML, pulls the `cross:` block, runs
`CrossTarget.fromMap`, and asserts provider / version-policy / sysroot
provenance / device host / sdk path-vs-url / flags / augment. Run from the
package root (the example dir is resolved relative to it).

## Still a sysroot-layer concern (not in the `cross:` block)

Image sha256 verification and the `-dev` apt package set are sysroot-layer
concerns (the `DepRule` shape), not toolchain identity, so they live outside
`cross:` and appear here only as comments.

## Surfacing `cross:` on the manifest

`EmbManifest.fromMap` doesn't read `cross:` yet. One field wires it in:

```dart
// in EmbManifest
final CrossTarget? cross;

// in fromMap(...)
cross: map['cross'] is Map
    ? CrossTarget.fromMap(map['cross'] as Map<dynamic, dynamic>)
    : null,
```

Until then, the test reads `cross:` directly from the YAML.
