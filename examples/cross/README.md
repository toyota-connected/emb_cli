# Cross-target manifest examples

One manifest per `ivi-homescreen/scripts/build_*.sh`, plus both Yocto-SDK
locations. Each exercises the `cross:` block parsed by `CrossTarget.fromMap`
(`lib/src/cross/cross_target.dart`).

`pi5.emb.yaml` and `radxa_zero3.emb.yaml` are **validated end-to-end** (`--build`
+ `--deb` produce aarch64 binaries and installable `.deb`s) and carry the full
`sysroot.dev_packages` / `backends` / `package` config; radxa builds all three
of its board-supported backends (wayland-egl, drm-kms-egl, software). The rest
are **parse / plan validated** (`--dry-run`); their values are lifted verbatim
from the scripts.

| manifest | script | provider | toolchain / sysroot | tuning | augment |
|---|---|---|---|---|---|
| `pi5.emb.yaml` ✅ | `build_pi.sh --target pi5` | `arm-gnu` | pinned 12.3.rel1 / raspios bookworm **image** | `-mcpu=cortex-a76` | libdisplay-info |
| `unoq.emb.yaml` | `build_unoq.sh` | `arm-gnu` | **derive** / **device rsync** | `-mcpu=cortex-a53` | libdisplay-info |
| `radxa_zero3.emb.yaml` ✅ | `build_radxa_zero3.sh` | `arm-gnu` | pinned 12.3.rel1 / radxa bookworm **image** (rootfs p3) | `-mcpu=cortex-a55` | libdisplay-info |
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

`build-all-backends.sh` is a tiny wrapper that drops the manifest next to a
given ivi-homescreen checkout and builds every backend:

```sh
./build-all-backends.sh ~/workspace-automation/app/ivi-homescreen
./build-all-backends.sh ~/.../ivi-homescreen --backend drm-kms-egl   # one
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

# 3b. Build, then package each backend binary into an .ipk (opkg/OpenEmbedded)
#     via opkg-build. Like --deb but Depends is explicit (cross.package.depends)
#     and the opkg arch comes from cross.package.ipk.arch (or a CPU-arch
#     default). Needs opkg-build (opkg-utils) on the host.
emb cross . --build --ipk

# 3c. Build, then package each backend binary into an .rpm via rpmbuild. Needs
#     cross.package.rpm.license; Requires is explicit (cross.package.depends)
#     plus rpm's automatic soname deps. Needs rpmbuild (rpm-build) on the host.
emb cross . --build --rpm

# 3d. Build, then package each backend binary into a relocatable .tar.gz
#     (binary + cross.package.files at their target paths; unpack with
#     `tar -C / -xzf`). No package manager needed — just tar.
emb cross . --build --targz

# 3e. Build + assemble the runnable app, then package it as a single-file
#     .flatpak (embedder + assets + engine) via flatpak-builder. Needs --app and
#     a cross.package.flatpak.app_id, plus flatpak-builder + the runtime on the
#     host. Output: cross-build-<triple>/dist/<app_id>_<branch>_<arch>.flatpak.
emb cross . --build --app ../my_flutter_app --flatpak

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
  backend; `cross-build-<triple>/dist/` — the generated package(s)
  (`.deb`/`.ipk`/`.rpm`/`.tar.gz`/`.flatpak`).
- `overlay-<triple>/`, `overlay-src/` — augment build prefix + sources.

## Packaging formats

All five formats hang off a single `cross.package:` block. The shared fields —
`name`, `version`, `maintainer`, `description`, `bin`, `install_dir`,
`depends`, `files` (`<source>: <dest>`, source relative to the manifest), and
`scripts` (`<preinst|postinst|prerm|postrm>: <source>`) — are reused by every
format; each format adds only what is specific to it. Pick formats per build
with `--deb` / `--ipk` / `--rpm` / `--targz` / `--flatpak` (combinable).

A `files:` entry may be a bare dest string, or a map that sets an explicit
mode — useful for an executable helper or a shared object whose source bit is
wrong:

```yaml
files:
  assets/app.toml: /etc/app/app.toml                  # preserves the source mode
  tools/helper: { to: /usr/bin/helper, mode: "0755" } # forced executable
  libs/libfoo.so: { to: /usr/lib/libfoo.so, mode: "0644" }
```

Without a `mode:`, the source file's own permission bits are preserved (so a
`+x` source stays executable). For flatpak the same applies — the file is
installed into the `/app` prefix with that mode instead of the old flat `0644`.

A complete block exercising every format:

```yaml
cross:
  # …provider / sysroot / backends…
  package:
    name: ivi-homescreen
    version: 1.0.0
    maintainer: "Joel Winarske <joel.winarske@linux.com>"
    description: "IVI Flutter shell, cross-built by emb"
    bin: shell/homescreen          # relative to each backend build dir
    install_dir: /usr/bin
    depends: [libc6]               # deb Depends / ipk Depends / rpm Requires
    files:                         # shipped by deb/ipk/rpm/targz (and flatpak)
      assets/app.toml: /etc/ivi-homescreen/app.toml
    scripts:                       # deb/ipk maintainer scripts; rpm scriptlets
      postinst: debian/postinst.sh

    rpm:
      license: MIT                 # required — rpm refuses to build without it
      release: "1"
      group: Applications/System
    ipk:
      arch: cortexa53              # opkg MACHINE tuning (else a CPU-arch default)
    flatpak:
      app_id: com.toyota.ivi.Homescreen
      runtime_version: '23.08'
      finish_args: [--share=ipc, --socket=wayland, --device=dri]
```

Per-format minimal snippets:

```yaml
# .deb  — emb cross . --build --deb
# Root-free; Depends auto-derived from the binary's DT_NEEDED (+ depends:).
package: { name: ivi-homescreen, version: 1.0.0, bin: shell/homescreen }
```

```yaml
# .ipk  — emb cross . --build --ipk   (opkg/OpenEmbedded; needs opkg-utils)
# Depends is explicit only (no dpkg db in a Yocto sysroot).
package:
  name: ivi-homescreen
  version: 1.0.0
  bin: shell/homescreen
  depends: [libc6]
  ipk: { arch: cortexa53 }         # optional; else aarch64/arm/… from the triple
```

```yaml
# .rpm  — emb cross . --build --rpm   (needs rpm-build)
# scripts: map to %pre/%post/%preun/%postun; License is mandatory.
package:
  name: ivi-homescreen
  version: 1.0.0
  bin: shell/homescreen
  scripts: { postinst: rpm/post.sh }
  rpm: { license: MIT, release: "1" }
```

```yaml
# .tar.gz  — emb cross . --build --targz   (needs only tar)
# Relocatable tree rooted at / (unpack with `tar -C / -xzf`). Ignores scripts:.
package:
  name: ivi-homescreen
  version: 1.0.0
  bin: shell/homescreen
  files: { assets/app.toml: /etc/ivi-homescreen/app.toml }
```

```yaml
# .flatpak  — emb cross . --build --app <dir> --flatpak
# Bundles the whole runnable app; needs flatpak-builder + the runtime. app_id
# is the only required field.
package:
  name: ivi-homescreen
  version: 1.0.0
  bin: shell/homescreen
  flatpak:
    app_id: com.toyota.ivi.Homescreen
    runtime_version: '23.08'
    finish_args: [--share=ipc, --socket=wayland, --device=dri]
```

> **deb auto-`Depends` needs a sysroot.** The `.deb` field is derived by mapping
> the binary's `DT_NEEDED` sonames to the packages that own them, looked up in
> the target sysroot's dpkg database plus the resolver's downloaded `-dev`
> `.deb`s. A `--target local` (native) build has neither, so its `.deb` comes
> out with an empty `Depends` — list runtime packages in `cross.package.depends`
> for native builds. This is deb-specific: `.rpm` instead carries soname-level
> `Requires` (e.g. `libc.so.6()(64bit)`) that rpmbuild extracts straight from
> the ELF, resolved by the target's package DB at install time, so it needs no
> sysroot; `.ipk` is explicit-only by design (Yocto sysroots ship no dpkg db).

## Sysroot provenance (arm-gnu)

The `cross.sysroot` block selects how the sysroot is acquired:

- `source: image` (+ `image_url`) — download + loop-mount + rsync. A bare
  top-level `image_url:` is accepted as shorthand and folds into this.
- `source: device` (+ `host`, `ssh_port`, `ssh_opts`) — rsync the rootfs from a
  live board. `ArmGnuCrossProvider` probes for rsync + passwordless sudo, then
  mirrors via `--rsync-path='sudo rsync'` when available. This is what makes
  the unoq **derive** policy work: the synced rootfs is what
  `_detectCodename` reads to pick the toolchain version.

Two more `cross.sysroot` knobs handle image quirks (see `radxa_zero3.emb.yaml`):

- `partition: <n>` — the 1-based rootfs partition in the image (default 2;
  radxa's is **3** — p2 there is a 300M boot partition).
- `symlinks: {<link-in-sysroot>: <target>}` — create symlinks after staging.
  `dev_packages` are always staged even if dpkg-status marks them installed (a
  device image can record a package installed yet strip its files); when the
  needed tree still isn't shipped under the expected name, a symlink bridges it.
  radxa's vendor `linux-libc-dev` omits `/usr/include/drm/`, so
  `usr/include/drm: libdrm` points `<drm/*.h>` at libdrm-dev's copies, letting
  the drm-kms-egl backend build.

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

## Building ivi-homescreen for AGL

[`agl_sdk_url.emb.yaml`](agl_sdk_url.emb.yaml) is a complete, buildable AGL
manifest (validated end-to-end against AGL **Marlin 13.0.3**, producing an
`aarch64-agl-linux` `homescreen` ELF).
[`agl_sdk_local.emb.yaml`](agl_sdk_local.emb.yaml) is the same recipe against an
already-installed SDK (`sdk_path` instead of `sdk_url`). Its `cross:` block:

```yaml
cross:
  provider: yocto-sdk
  triple: aarch64-agl-linux           # AGL distro triple; do not omit
  sdk_url: https://archive.automotivelinux.org/marlin/13.0.3/raspberrypi4/deploy/sdk/poky-agl-glibc-x86_64-agl-demo-platform-crosssdk-aarch64-raspberrypi4-64-toolchain-13.0.3.sh
  host_build_tools: true              # AGL pins cmake 3.16.5 (< the 3.20 floor)
  defines:
    DISABLE_PLUGINS: 'ON'
  backends:
    wayland-egl:                      # AGL is Wayland (agl-compositor)
      BUILD_BACKEND_WAYLAND_EGL: 'ON'
      BUILD_BACKEND_WAYLAND_VULKAN: 'OFF'
      ENABLE_AGL_SHELL_CLIENT: 'ON'   # agl-compositor shell protocol client
  package: { name: ivi-homescreen, version: 13.0.3, bin: shell/homescreen }
```

`emb cross <file> --build` uses the manifest **file's parent** as the CMake
source, so copy the manifest next to the ivi-homescreen checkout, then build:

```sh
cp agl_sdk_url.emb.yaml <path>/ivi-homescreen/agl.emb.yaml
# Downloads + installs the SDK (~690 MB), then configures + builds.
emb cross <path>/ivi-homescreen/agl.emb.yaml --build --host-tools
# → cross-build-aarch64-agl-linux-<hash>/build-wayland-egl/shell/homescreen
#   (an aarch64 ELF linking libEGL/libGLESv2/libwayland-egl, agl-shell client in)
```

Three AGL specifics make this work:

- **`triple: aarch64-agl-linux`** — AGL's own distro triple. Omit it and the OE
  env only yields `aarch64-linux`.
- **`ENABLE_AGL_SHELL_CLIENT: 'ON'`** — compiles the agl-compositor shell
  protocol client into the `wayland-egl` backend (AGL is Wayland, not DRM/KMS).
- **`host_build_tools: true`** (or `--host-tools`) — AGL SDKs pin an old
  `nativesdk` cmake (3.16.5), and the OE env-setup prepends the SDK's `bin` to
  `PATH`, so its cmake wins. ivi-homescreen needs cmake >= 3.20. This runs the
  **host's** cmake (or meson) with the SDK's OE env + toolchain file unchanged.
  Drop it for an SDK whose cmake is new enough.

The first build writes [`emb.lock`](../../README.md#reproducible-builds-emblock)
pinning the resolved `OECORE_SDK_VERSION` + the installer's sha256; later builds
verify it (re-run with `--update-lock` after intentionally changing the SDK).

> The AGL `sdk_url` here is a live **archive** URL. AGL moves old releases from
> `download.automotivelinux.org` to `archive.automotivelinux.org` (the historic
> jellyfish `download` URL now 404s), and the newest releases (trout/unagi) may
> not publish a prebuilt crosssdk — Marlin does. Confirm the URL for your
> release before building.

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

`EmbManifest.fromMap` reads the `cross:` block into a typed
`EmbManifest.cross` (`CrossTarget?`), so a package's own `emb.yaml` can
self-describe its cross toolchain/sysroot. It's null when there's no `cross:`
block or it has no resolvable provider, and parsing never throws — a malformed
`cross:` won't break unrelated commands (`deps`/`sync`/`doctor`). For a
multi-target block (`cross.targets`) it's the shared base; `CrossProjectResolver`
does per-target merging.

The example test above parses each `cross:` block directly with
`CrossTarget.fromMap` to assert per-field; consumers should prefer
`EmbManifest.cross`.
