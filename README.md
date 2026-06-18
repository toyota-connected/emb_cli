# emb — Flutter Embedder CLI

[![style: very good analysis][very_good_analysis_badge]][very_good_analysis_link]
[![License: Apache-2.0][license_badge]][license_link]

`emb` provisions a Flutter **embedded-Linux** development workspace and builds
deployable app bundles for embedders such as
[ivi-homescreen](https://github.com/meta-flutter/ivi-homescreen). It's a Dart
port of [meta-flutter/workspace-automation](https://github.com/meta-flutter/workspace-automation)
(`flutter_workspace.py` + `create_aot.py`).

The whole flow is a handful of commands:

```
deps → repos → Flutter SDK → engine → AOT → ivi-homescreen bundle
```

- **Host dependency install** in one transaction (PackageKit on Linux), with
  `WhatProvides` resolution so `pkg-config`, `libjpeg-devel`, etc. just work.
- **Prebuilt Flutter engine** fetched from
  [meta-flutter/flutter-engine](https://github.com/meta-flutter/flutter-engine)
  releases (auto, keyed by the SDK's engine commit).
- **Cross-compile AOT** for `arm64` / `riscv64` from an `x86_64` host using the
  engine's simulator `gen_snapshot` — no qemu (the artifact is self-contained).
- **Self-describing packages**: a package declares its build in a manifest and
  `emb build <dir>` does the rest.

---

## Requirements

- **Dart SDK ≥ 3.10.1** (to run/build the `emb` tool itself).
- **Linux** for host **dependency install** (PackageKit — dnf/apt/zypper). The
  macOS (Homebrew) and Windows (WinGet) backends are stubbed in this build; all
  other commands are cross-platform.
- `git`, `tar`, `curl` on `PATH`.
- Cross-compiling to a device arch is supported **from an x86_64 host**.

---

## Install

```sh
# From the package root:
dart pub get
dart pub global activate --source=path .   # puts `emb` on PATH

emb --help
```

Make sure the pub-global bin dir (`$PUB_CACHE/bin`, e.g. `~/.pub-cache/bin`) is
on `PATH`. You can also run without activating:

```sh
dart run bin/emb.dart <command>     # from the package root
```

> The Linux backend loads `packagekit_dart`'s native bridge
> (`libpackagekit_nc.so`). `emb` locates it automatically — from the package's
> own build, or from the `package:hooks` build-hook output under
> `.dart_tool/`. Override with `PK_NC_LIB=/path/to/libpackagekit_nc.so`.

---

## Quick start

```sh
# 0. Check host detection + package backend
emb doctor

# 1. Provision the workspace (host deps + repos + Flutter SDK + engine)
emb setup --config ../configs --yes

# 2. Load the environment it wrote (Flutter/Dart on PATH, FLUTTER_WORKSPACE, …)
. ./setup_env.sh

# 3. Build an ivi-homescreen bundle for a Raspberry Pi (arm64), release AOT
emb bundle --app-path ./app/my_app --arch arm64 --build

# 4. Run it on the target
#    ivi-homescreen --b=<workspace>/bundle/my_app-release-arm64
```

`emb setup` runs every phase; you can also run them individually
(`emb deps`, `emb sync`, `emb flutter`, `emb engine`).

---

## Workspace & path resolution

Every command that touches the workspace resolves its root **in this order**:

1. `--workspace <dir>` (explicit flag), else
2. the `$FLUTTER_WORKSPACE` environment variable, else
3. the current working directory.

```
<workspace>/                              # the resolved root
  app/                                    # cloned source repositories
  flutter/                                # Flutter SDK
  bundle/                                 # built bundles (default output)
  setup_env.sh                            # generated environment script
  .config/flutter_workspace/
    flutter-engine/<commit>/...           # downloaded + extracted engine SDKs
    flutter-engine/bundle-<mode>-<arch>/  # staged engine halves (icudtl + .so)
```

---

## Command reference

```
emb <command> [arguments]
```

### Global options

| Option | Description |
|---|---|
| `-h`, `--help` | Print usage. Works at the top level and per command (`emb <cmd> --help`). |
| `-v`, `--version` | Print the CLI version. |
| `--[no-]verbose` | Noisy logging, including every shell command executed. |

`--workspace` (`-w`), shown on most commands, follows the resolution order
above. `--mode`/`--arch` defaults and value sets differ **per command** — see
each entry.

---

### `emb doctor`

Report host detection (os / arch / distro) and package-manager backend
availability. No options. Exit code is non-zero if the backend is unavailable.

```sh
emb doctor
```

---

### `emb setup`

One-shot provision: **deps → repos → Flutter SDK → engine**, then writes
`setup_env.sh`. Each phase is individually skippable.

| Option | Default | Description |
|---|---|---|
| `-c`, `--config <dir>` | `configs` | Legacy JSON config directory. |
| `-p`, `--packages <dir>` | — | Directory to discover self-describing `emb` manifests. |
| `--enable <id>` | — | Force-load the config with this `id` (overrides `load: false`). Repeatable; unmatched ids ignored. |
| `--disable <id>` | — | Skip the config with this `id` (overrides `load: true`). Repeatable; unmatched ids ignored. |
| `-w`, `--workspace <dir>` | resolution order | Workspace root. |
| `--flutter-version <ref>` | `globals.json` `flutter_version` | Flutter version/tag/branch. |
| `--arch <arch>` | host arch | Engine arch to prefetch. |
| `-m`, `--mode <mode>` | `release` | Engine runtime modes to prefetch (repeatable): `release`, `profile`, `debug`. |
| `-y`, `--yes` | off | Skip the deps confirmation prompt (CI). |
| `--skip-deps` | off | Skip host dependency install. |
| `--skip-sync` | off | Skip repository sync. |
| `--skip-flutter` | off | Skip Flutter SDK install. |
| `--skip-engine` | off | Skip engine artifact fetch. |

```sh
emb setup --config ../configs --yes
emb setup --config ../configs --skip-deps --skip-sync   # SDK + engine only
emb setup --config ../configs --enable weston --disable agl-compositor
```

> **Config selection** (applies to `setup`, `deps`, and `sync`): legacy
> `--config` components apply only when their `load` flag is logically true.
> `--enable <id>` / `--disable <id>` override that per component, matched by
> `id`; ids matching nothing are ignored, and load order is preserved.

---

### `emb deps`

Coalesce host dependencies across all selected manifests, filter to what's
**missing** on this host, and install the union in **one** transaction.

| Option | Default | Description |
|---|---|---|
| `-c`, `--config <dir>` | `configs` | Legacy JSON config directory. **Repeatable.** |
| `-p`, `--packages <dir>` | — | Directory to discover self-describing `emb` manifests. **Repeatable.** |
| `--enable <id>` | — | Force-load the config with this `id` (overrides `load: false`). Repeatable; unmatched ids ignored. |
| `--disable <id>` | — | Skip the config with this `id` (overrides `load: true`). Repeatable; unmatched ids ignored. |
| `--dry-run` | off | Resolve and print the install plan without changing the system. |
| `-y`, `--yes` | off | Skip the confirmation prompt (CI). |

```sh
emb deps --config ../configs --dry-run      # plan only
emb deps --config ../configs --yes          # install in one transaction
```

---

### `emb sync`

Clone/update source repositories into `<workspace>/app` (bounded concurrency).

| Option | Default | Description |
|---|---|---|
| `-c`, `--config <dir>` | `configs` | Legacy JSON config directory. **Repeatable.** |
| `-p`, `--packages <dir>` | — | Directory to discover self-describing `emb` manifests. |
| `--enable <id>` | — | Force-load the config with this `id` (overrides `load: false`). Repeatable; unmatched ids ignored. |
| `--disable <id>` | — | Skip the config with this `id` (overrides `load: true`). Repeatable; unmatched ids ignored. |
| `--repos <file>` | — | A JSON file containing a bare array of repo entries. **Repeatable.** |
| `-w`, `--workspace <dir>` | resolution order | Workspace root. |
| `-j`, `--concurrency <n>` | `4` | Maximum concurrent git operations. |

```sh
emb sync --config ../configs -j 8
```

---

### `emb flutter`

Install the Flutter SDK into `<workspace>/flutter`, then emit
`<workspace>/setup_env.sh` so `FLUTTER_WORKSPACE` (and the SDK's Flutter/Dart on
`PATH`) match the workspace just provisioned — i.e. the `-w` target.

| Option | Default | Description |
|---|---|---|
| `-w`, `--workspace <dir>` | resolution order | Workspace root. Also becomes `FLUTTER_WORKSPACE` in the emitted `setup_env.sh`. |
| `--flutter-version <ref>` | `globals.json` `flutter_version` | Version/tag/branch to check out. |
| `-c`, `--config <dir>` | `configs` | Directory to read `globals.json` from. |
| `--configure` | off | Run `flutter config` (desktop + custom devices) and `flutter doctor` after install. |

```sh
emb flutter -w /tmp/ws1 --flutter-version 3.44.2
. /tmp/ws1/setup_env.sh                   # FLUTTER_WORKSPACE=/tmp/ws1
```

---

### `emb engine`

Fetch prebuilt Flutter engine artifacts (auto fetch-else-build). Modes you don't
fetch here are auto-fetched on demand by `emb bundle`/`emb build`.

| Option | Default | Description |
|---|---|---|
| `-w`, `--workspace <dir>` | resolution order | Workspace root. |
| `--commit <sha>` | `<workspace>/flutter/bin/internal/engine.version` | Engine commit to fetch. |
| `--arch <arch>` | host arch | Engine arch token (see [Architectures](#architectures--cross-compiling)). |
| `-m`, `--mode <mode>` | `release` | Runtime modes to fetch (repeatable): `release`, `profile`, `debug`. |
| `--clean` | off | Re-stage bundles even when already present. |
| `--check` | off | Only check prebuilt availability; do not download. |

```sh
emb engine --arch arm64 --mode release --mode profile
emb engine --arch riscv64 --check       # is a prebuilt available?
```

---

### `emb aot`

Build the AOT image (`libapp.so`) for a Flutter app — the AOT primitive used by
`emb bundle --build`. **Debug is not AOT**, so only `release`/`profile` apply.

| Option | Default | Description |
|---|---|---|
| `-a`, `--app-path <dir>` | **mandatory** | Path to the Flutter application to build. |
| `-w`, `--workspace <dir>` | resolution order | Workspace root. |
| `-m`, `--mode <mode>` | `release` | Runtime modes to build (repeatable): `release`, `profile`. |
| `--arch <arch>` | host arch | Target arch for `gen_snapshot` (e.g. `arm64` for a Pi). |
| `--gen-snapshot <path>` | auto-resolved | Explicit `gen_snapshot` path (overrides resolution). |
| `--glibc-sysroot <dir>` | artifact's bundled `clang_x64/lib64` | Directory with `ld-linux` + libc to run `gen_snapshot` under. |

```sh
emb aot --app-path ./app/my_app --arch arm64 --mode release --mode profile
```

---

### `emb bundle`

Assemble an ivi-homescreen bundle from app + engine artifacts. With `--build` it
runs `emb aot` first; the engine SDK for the `(mode, arch)` is fetched
implicitly if not already cached.

| Option | Default | Description |
|---|---|---|
| `-a`, `--app-path <dir>` | **mandatory** | Path to the Flutter application. |
| `-w`, `--workspace <dir>` | resolution order | Workspace root. |
| `-m`, `--mode <mode>` | `release` | Single mode: `debug` (JIT, no AOT), `profile`, or `release` (AOT). |
| `--arch <arch>` | host arch | Target arch (e.g. `arm64`). |
| `-o`, `--output <dir>` (alias `--out`) | `<workspace>/bundle/<app>-<mode>-<arch>` | Output bundle directory — any path. |
| `--build` | off | Run `emb aot` first to (re)build `flutter_assets` + `libapp.so`. |

```sh
emb bundle --app-path ./app/my_app --arch arm64   --build                # release
emb bundle --app-path ./app/my_app --arch arm64   --build --mode debug   # JIT
emb bundle --app-path ./app/my_app --arch riscv64 --build --mode profile
emb bundle --app-path ./app/my_app --build                               # host
emb bundle --app-path ./app/my_app --arch arm64 --output /tmp/out        # custom path
```

---

### `emb build`

Build a **self-describing** package — a directory with an `emb.yaml` (or an
`emb:` key in `pubspec.yaml`) — into bundles, using the manifest's `build:`
matrix. The package directory is a **positional argument** (mandatory; omitting
it prints a usage error).

```
emb build <package-dir> [options]
```

| Option | Default | Description |
|---|---|---|
| `<package-dir>` | **mandatory (positional)** | Directory containing `emb.yaml` or a `pubspec.yaml` with an `emb:` key. |
| `-w`, `--workspace <dir>` | resolution order | Workspace root. |
| `--arch <arch>` | manifest's `archs` | Override target arch(es). **Repeatable.** |
| `-m`, `--mode <mode>` | manifest's `modes` | Override mode(s): `debug`, `profile`, `release`. **Repeatable.** |
| `--no-build` | off | Assemble from existing artifacts; skip compiling. |

```sh
emb build ./app/my_app                              # full manifest matrix
emb build ./app/my_app --arch arm64 --mode release  # override the matrix
emb build ./app/my_app --no-build                   # assemble only
```

#### Manifest (`emb.yaml`)

```yaml
id: my_app
type: app
build:
  app_path: .              # Flutter app dir, relative to this manifest (default ".")
  archs: [arm64, x86_64]   # target architectures (default: host)
  modes: [release, debug]  # default: [release]
  output: bundles          # optional output dir, relative to the workspace
deps:                      # optional host packages, by OS / distro
  linux:
    fedora: [pkg-config, freetype-devel]
    ubuntu: [pkg-config, libfreetype-dev]
  macos: [pkg-config, freetype]
  windows: [Kitware.CMake]
```

---

### `emb cross`

Cross-compile a **native** embedder (e.g. ivi-homescreen) for an `arm64` /
`riscv64` target from an `x86_64` host, driven by the manifest's `cross:` block.
This is the C/C++ toolchain + sysroot path — distinct from the Dart AOT cross
used by `emb build` / `emb bundle`. Three providers: `arm-gnu` (a downloaded ARM
GNU toolchain plus a sysroot unpacked from a distro image or rsync'd from a
device), `yocto-recipe` (a located OE `recipe-sysroot`), and `yocto-sdk` (a
`populate_sdk` install). The input is a **positional** project dir (with a
`.emb/` manifest directory or a top-level `emb.yaml`) or an explicit manifest
file.

```
emb cross <project-dir|manifest.yaml> [options]
```

| Option | Default | Description |
|---|---|---|
| `<project-dir\|manifest>` | **mandatory (positional)** | Project dir (a `.emb/` directory, else `emb.yaml`), or a manifest file. |
| `-w`, `--workspace <dir>` | resolution order | Workspace root. |
| `-t`, `--target <name>` | flat manifest's target, else `local` | Select a target (e.g. `rpi5`, `imx93-evk`): a `cross.targets` entry or a per-board `.emb/` file. `local`/`host` is a native build on this machine. With multiple targets, omitting `--target` defaults to `local`. |
| `--list-targets` | off | List the targets this project defines — `cross.targets` entries and `.emb/` files, grouped by family — plus the built-in `local`, then exit. |
| `--dry-run` | off | Report the resolution plan (provider, toolchain, sysroot, preflight, augment, backends) with no download / mount / ssh. |
| `--prepare` | off | After resolving, build the `augment` libraries into the overlay. |
| `--build` | off | Configure + build the embedder under the resolved profile, one build per `cross.backends` entry. |
| `--backend <name>` | all | Build only the named `cross.backends` entries. Repeatable. |
| `--deb` | off | With `--build`: package each backend binary into a root-free `.deb` (Depends auto-derived from the binary's needed libraries). |
| `--app <dir>` | — | With `--build`: also build this Flutter app for the target and assemble a **runnable bundle** (embedder + engine + flutter_assets + icudtl + libapp), runnable as `./homescreen --b=.`. |
| `-m`, `--mode <mode>` | `release` | Runtime mode for the `--app` bundle (`debug`/`profile`/`release`). |
| `--tar` | off | Also produce a `.tar.gz` of each runnable bundle. |
| `--deploy <user@host>` | — | With `--app`: send each runnable bundle to the board over SSH — rsync when the target has it, else a tar-over-SSH fallback (port/opts reused from `cross.sysroot` when device-sourced). |
| `--deploy-dir <path>` | `ivi-homescreen` | Remote destination dir for `--deploy`. |
| `--run` | off | After `--deploy`, run the bundle on the target over SSH (`./homescreen --b=.`). |
| `--clean` | off | Remove this target's build + overlay dirs (keeps the toolchain + sysroot), then exit. |
| `--clean-all` | off | Also remove the downloaded / extracted toolchain + sysroot and the apt / deb caches, then exit. |
| `--update-lock` | off | Regenerate this target's `emb.lock` entry from the resolved toolchain/sysroot (accepts an intentional URL / version change). See [Reproducible builds](#reproducible-builds-emblock). |
| `--no-verify` | off | Skip `emb.lock` verification for this resolve (don't fail on a drifted artifact sha or version). |
| `--host-tools` | off | With `--build`: use the host's `cmake`/`meson` instead of the SDK's, for OE SDKs that pin an old one (e.g. AGL ships cmake 3.16.5). The OE env + toolchain/cross file are unchanged. Also set via `cross.host_build_tools`. |
| `--install-deps` | off | Install the provider's missing preflight host tools via the host package backend (PackageKit/brew) instead of erroring. Opt-in; needs privileges. Falls back to printing the manual install command when no backend is reachable. |

```sh
emb cross ./app/ivi-homescreen --dry-run      # plan only, no side effects
emb cross ./app/ivi-homescreen --build        # toolchain + sysroot + build
emb cross ./app/ivi-homescreen --build --deb  # ...and package a .deb
emb cross ./app/ivi-homescreen --clean        # drop build dirs (keep toolchain)
emb cross ./app/ivi-homescreen --clean-all    # drop everything for this target
```

Everything is **root-free**: the sysroot is extracted with `debugfs` /
`dpkg-deb`, and `-dev` packages are resolved against the image's own apt sources
— no `apt`, no `chroot`, no `sudo`. Validated end-to-end on Raspberry Pi
(arm-gnu, raspios bookworm): `--build --deb` produces an aarch64 ELF and an
installable `.deb`. See [`examples/cross/`](examples/cross/) for one manifest
per board (`pi5` is the validated end-to-end example) and the full schema.

#### Manifest (`cross:` block)

```yaml
cross:
  provider: arm-gnu               # arm-gnu | yocto-recipe | yocto-sdk
  toolchain_version: 12.3.rel1    # pinned ARM GNU release (or version_policy: derive)
  image_url: https://.../raspios-bookworm-arm64-lite.img.xz
  cpu_flags: [-mcpu=cortex-a76]   # pi5; pi4=cortex-a72, pi-zero-2=cortex-a53
  sysroot:
    partition: 2                  # rootfs partition in the image (default 2)
    dev_packages: [libdrm-dev, libegl-dev, libgbm-dev, libinput-dev]
  augment:                        # libs built from source when the sysroot is too old
    - { pkg: libdisplay-info, min: "0.2.0", url: https://.../libdisplay-info-0.2.0.tar.gz, build: meson, static: true }
  defines:                        # -D<name>=<value> applied to every build
    CMAKE_INSTALL_PREFIX: /usr
  cmake_args: [-Wno-dev]          # raw cmake configure flags (cmake only)
  backends:                       # one build per entry; -D<key>=<value> each
    drm-kms-egl: { BUILD_BACKEND_DRM_KMS_EGL: 'ON', DISABLE_PLUGINS: 'ON' }
  package:                        # optional, consumed by --deb
    name: ivi-homescreen
    version: 1.0.0
    bin: shell/homescreen         # binary, relative to each backend build dir
    install_dir: /usr/bin
```

#### Multiple platforms in one manifest (`cross.targets`)

To target several boards from a single manifest, put the shared config at the
`cross:` level and a per-board override under `cross.targets`, then pick one with
`--target`:

```yaml
cross:
  provider: arm-gnu               # shared by every target
  toolchain_version: 12.3.rel1
  sysroot: { dev_packages: [libdrm-dev, libegl-dev, libgbm-dev, libinput-dev] }
  backends: { drm-kms-egl: { BUILD_BACKEND_DRM_KMS_EGL: 'ON' } }
  targets:                        # per-board overrides
    rpi5:        { image_url: …raspios…, cpu_flags: [-mcpu=cortex-a76] }
    rpi4:        { image_url: …raspios…, cpu_flags: [-mcpu=cortex-a72] }
    rpi-zero-2w: { image_url: …raspios…, cpu_flags: [-mcpu=cortex-a53] }
    radxa-zero3: { image_url: …radxa…,   cpu_flags: [-mcpu=cortex-a55] }
```
```sh
emb cross . --list-targets
emb cross . --target rpi5 --build --deb
emb cross . --target radxa-zero3 --build
```

A target's fields shallow-merge over the shared block (a top-level `image_url`
folds into `sysroot`). Working dirs are content-hash-keyed, so boards that share
a sysroot (rpi4/rpi5/zero-2w — same image, only `-mcpu` differs) **extract it
once**, while a different image (radxa) gets its own. A manifest with no
`cross.targets` behaves exactly as before (one implicit target).

#### A `.emb/` directory of per-board manifests

When the boards diverge enough that one file gets unwieldy (e.g. a Yocto board
with its own provider, recipe, and augment list next to a Raspberry Pi family),
put a **`.emb/` directory** at the project root instead. `emb cross <project>`
prefers `<project>/.emb/` over a top-level `emb.yaml`:

```text
my-app/
  .emb/
    base.emb.yaml          # shared: provider defaults, defines, package, sysroot deps
    raspberry-pi.emb.yaml  # a family file: cross.targets → rpi4, rpi5, rpi-zero-2w
    imx93.emb.yaml         # a flat per-board file: platform.name → imx93-evk
```

Each file declares a `platform:` block, and the selectable target list is the
**union across every file**:

```yaml
# imx93.emb.yaml
platform:
  name: imx93-evk                 # the --target value
  description: NXP i.MX93 EVK (drm-kms-egl)
cross:
  provider: yocto-recipe          # overrides base.emb.yaml's provider
  triple: aarch64-poky-linux
  backends: { drm-kms-egl: { BUILD_BACKEND_DRM_KMS_EGL: 'ON' } }
```

```sh
emb cross my-app --list-targets        # imx93-evk, rpi4, rpi5 [raspberry-pi], … + local
emb cross my-app --target imx93-evk --build
emb cross my-app --target rpi5 --build --deb
```

Resolution merges three layers: `.emb/base.emb.yaml` (a **deep** merge — nested
maps like `cross.sysroot` combine, so base defaults survive what a board omits),
then the board file's `cross:`, then a `cross.targets[variant]` shallow override.
A flat file contributes one target (named by `platform.name`); a family file
contributes one per `cross.targets` key, grouped under its `platform.name`.
Duplicate target names across files are an error. Native `local` uses
`base.emb.yaml`'s shared block.

There's always a built-in **`local`** target (alias `host`): a native build on
this machine — no cross toolchain or sysroot, host compiler + system libraries
(install host dev deps via `emb deps`). It's the **default** when a manifest
defines `cross.targets` and you don't pass `--target`, so `emb cross . --build`
builds for the dev box while `--target rpi5` cross-builds.

```sh
emb cross . --build            # native local build (default with cross.targets)
emb cross . --target local     # …the same, explicit (or --target host)
emb cross . --target rpi5 --build
```

#### Reproducible builds (`emb.lock`)

A cross resolve pins what it actually used to **`emb.lock`** at the project root,
keyed by target — so a moved or changed URL fails loudly instead of silently
building against different bytes. It is written for real resolves only;
`--dry-run` never touches it.

On the **first** resolve of a target, `emb.lock` is created automatically
(pub-style). On **later** resolves the toolchain/sysroot is re-verified against
it and the build **fails on drift**; `--update-lock` accepts the change (and
rewrites the entry), `--no-verify` skips the check for one run. Commit `emb.lock`
so CI and teammates resolve the same inputs.

What each provider pins:

| Provider | Pinned facts |
|---|---|
| `arm-gnu` | sha256 of the toolchain tarball and the distro image (byte-exact); a device-sourced sysroot records provenance only — a live host can't be content-pinned. |
| `yocto-sdk` | `OECORE_SDK_VERSION`, plus the sha256 of the `populate_sdk` installer when fetched from `sdk_url`. |
| `yocto-recipe` | the located recipe version + the native gcc version (it downloads nothing, so there is no artifact to sha). |

Drift is reported for: a changed artifact sha (moved URL), a changed resolved /
derived version, or edited manifest inputs (the content-addressed
`sysroot_key` / `build_key`). An artifact not re-fetched on a warm cache is
skipped, so verification fires exactly when bytes are re-materialized.

```sh
emb cross . --target rpi5 --build                 # first run → writes emb.lock
emb cross . --target rpi5 --build                 # later → verifies, fails on drift
emb cross . --target rpi5 --build --update-lock    # accept an intentional change
```

> Note: `emb.lock` lives at the project root keyed by target name, so loosely
> co-located single-file manifests that share one directory would collide on the
> `default` target. One project = one directory is the intended layout.

---

### `emb env`

(Re)generate or print `setup_env.sh` (`PATH` for Flutter/Dart,
`FLUTTER_WORKSPACE`, `PUB_CACHE`, `XDG_CONFIG_HOME`, the engine version, …).

`emb setup` and `emb flutter` already emit this file, so the standalone command
is for what they don't cover: regenerating after the workspace has **moved**
(the baked-in `FLUTTER_WORKSPACE` is absolute), previewing the env on stdout, or
writing it to a custom path. It has no side effects beyond the one file — it
never clones or installs, and warns if `<workspace>/flutter` is absent (the env
would point at a missing SDK; run `emb flutter -w <root>` first).

| Option | Default | Description |
|---|---|---|
| `-w`, `--workspace <dir>` | resolution order | Workspace root (becomes `FLUTTER_WORKSPACE`). |
| `-o`, `--output <path>` | `<workspace>/setup_env.sh` | Output file path. |
| `--print` | off | Print to stdout instead of writing a file. |

```sh
emb env                 # (re)write <workspace>/setup_env.sh
emb env -w /tmp/ws1     # regenerate after moving the workspace
emb env --print         # preview on stdout
```

---

### `emb update`

Update the CLI itself (via `pub`). No options.

```sh
emb update
```

---

## Modes

| `--mode`  | How it builds                         | Bundle contents | Valid in |
|-----------|---------------------------------------|-----------------|----------|
| `debug`   | JIT — `flutter build bundle --debug`  | `kernel_blob.bin`, **no** `libapp.so` | `bundle`, `build`, `engine`, `setup` |
| `profile` | AOT (`gen_snapshot`)                  | `libapp.so` (+ profile engine) | all |
| `release` | AOT (`gen_snapshot`)                  | `libapp.so` (+ release engine) | all |

`emb aot` only accepts `release`/`profile` (debug isn't AOT). Where a command
takes **multiple** modes (`aot`, `build`, `engine`, `setup`), repeat the flag:
`--mode release --mode profile`. `emb bundle` takes a **single** mode.

A bundle is the directory ivi-homescreen consumes:

```
<bundle>/
  data/flutter_assets/        # app code + assets
  data/icudtl.dat             # from the engine
  lib/libflutter_engine.so    # from the engine (per mode)
  lib/libapp.so               # AOT image (profile/release only)
```

---

## Architectures & cross-compiling

`--arch` accepts machine names or Flutter tokens; they normalize to one of four
**engine arch tokens** used in paths and bundle names:

| You pass | Normalized token |
|---|---|
| `x64`, `x86_64`, `amd64` | `x86_64` |
| `arm64`, `aarch64` | `arm64` |
| `arm`, `armv7`, `armv7hf`, `armhf` | `armv7hf` |
| `riscv64` | `riscv64` |

Cross-compile is **x86_64 host → target arch**. The meta-flutter engine SDK
ships a host-x86_64 **simulator** `gen_snapshot` that emits target code and
carries its own loader/libc in `clang_x64/lib64`, so it runs on any host glibc —
**no qemu required**. `emb` selects and runs it automatically; `--gen-snapshot`
/ `--glibc-sysroot` override if needed. Building **on** an arm64 host targets
arm64 natively.

---

## Development

```sh
dart pub get
dart analyze
dart test
```

The macOS/Windows package backends live in `lib/src/pkg/_platform/` and are
excluded from the default (Linux) build — see that folder's `README.md`. Dart
has no OS-conditional dependencies, so they're wired in only on per-OS builds
that add `brew_dart` / `winget_dart`.

[license_badge]: https://img.shields.io/badge/license-Apache%202.0-blue.svg
[license_link]: https://opensource.org/licenses/Apache-2.0
[very_good_analysis_badge]: https://img.shields.io/badge/style-very_good_analysis-B22C89.svg
[very_good_analysis_link]: https://pub.dev/packages/very_good_analysis
