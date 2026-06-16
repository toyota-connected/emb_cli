# emb — Flutter Embedder CLI

[![style: very good analysis][very_good_analysis_badge]][very_good_analysis_link]
[![License: Apache-2.0][license_badge]][license_link]

`emb` provisions a Flutter **embedded-Linux** development workspace and builds
deployable app bundles for embedders such as
[ivi-homescreen](https://github.com/meta-flutter/ivi-homescreen). It's a Dart
port of [meta-flutter/workspace-automation](https://github.com/meta-flutter/workspace-automation)
(`flutter_workspace.py` + `create_aot.py`).

It does the whole flow in a handful of commands:

```
deps → repos → Flutter SDK → engine → AOT → ivi-homescreen bundle
```

- **Host dependency install** in one transaction (PackageKit on Linux), with
  `WhatProvides` resolution so `pkg-config`, `libjpeg-devel`, etc. just work.
- **Prebuilt Flutter engine** fetched from
  [meta-flutter/flutter-engine](https://github.com/meta-flutter/flutter-engine)
  releases (auto, keyed by the SDK's engine commit).
- **Cross-compile AOT** for `arm64` / `riscv64` from an `x86_64` host using the
  engine's simulator `gen_snapshot` (no qemu — the artifact is self-contained).
- **Self-describing packages**: a package declares its build in its manifest and
  `emb build <package>` does the rest.

---

## Requirements

- Dart SDK ≥ 3.10.1 (the `emb` tool itself).
- Linux for host **dependency install** (PackageKit — dnf/apt/zypper). The
  macOS/Windows package backends are stubbed in this build.
- `git`, `tar`, `curl` on PATH.
- Cross-compiling to a device arch is supported **from an x86_64 host**.

## Install

```sh
# From this directory:
dart pub get
dart pub global activate --source=path .

# Then (ensure the pub-global bin dir is on PATH):
emb --help
```

You can also run it without activating: `dart run bin/emb.dart <command>`.

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

`emb setup` runs everything; you can also run the phases individually
(`emb deps`, `emb sync`, `emb flutter`, `emb engine`). The workspace root is
`$FLUTTER_WORKSPACE`, else the current directory, else `--workspace <dir>`.

---

## Building bundles

A bundle is the directory layout `ivi-homescreen` consumes:

```
<bundle>/
  data/flutter_assets/        # app code + assets
  data/icudtl.dat             # from the engine
  lib/libflutter_engine.so    # from the engine (per mode)
  lib/libapp.so               # AOT image  (profile/release only)
```

### Modes

| `--mode`  | how it builds                         | bundle contents              |
|-----------|---------------------------------------|------------------------------|
| `debug`   | JIT — `flutter build bundle --debug`  | `kernel_blob.bin`, **no** `libapp.so` |
| `profile` | AOT (`gen_snapshot`)                  | `libapp.so` (+ profile engine) |
| `release` | AOT (`gen_snapshot`)                  | `libapp.so` (+ release engine) |

Defaults: **`--mode release`**, **`--arch` = host arch**. The engine SDK for the
selected `(mode, arch)` is **fetched implicitly** if it isn't already cached, so
you don't have to run `emb engine` first.

```sh
emb bundle --app-path ./app/my_app --arch arm64   --build               # release
emb bundle --app-path ./app/my_app --arch arm64   --build --mode debug  # JIT
emb bundle --app-path ./app/my_app --arch riscv64 --build --mode profile
emb bundle --app-path ./app/my_app --build                              # host (x86_64)
emb bundle --app-path ./app/my_app --arch arm64 --out /tmp/bundle-out   # custom path
```

### Manifest-driven (`emb build`)

Give a package an `emb` manifest (an `emb.yaml`, or an `emb:` key in
`pubspec.yaml`) so it builds itself with no flags:

```yaml
# emb.yaml
id: my_app
type: app
build:
  app_path: .            # Flutter app dir, relative to this manifest
  archs: [arm64, x86_64] # target architectures (default: host)
  modes: [release, debug]# default: [release]
  output: bundles        # optional output dir, relative to the workspace
deps:                    # optional host packages, by OS / distro
  linux:
    fedora: [pkg-config, freetype-devel]
    ubuntu: [pkg-config, libfreetype-dev]
```

```sh
emb build ./app/my_app            # builds the full arch × mode matrix
emb build ./app/my_app --arch arm64 --mode release   # override the matrix
emb build ./app/my_app --no-build # assemble from existing artifacts only
```

---

## Cross-compiling

Cross-compile is **x86_64 host → target arch** (`arm64`, `riscv64`, …). The
meta-flutter engine SDK ships a host-x86_64 **simulator** `gen_snapshot`
(`linux_simarm64`) that emits target code and carries its own loader/libc in
`clang_x64/lib64`, so it runs on any host glibc — **no qemu required**. `emb`
selects and runs it automatically; `--gen-snapshot` / `--glibc-sysroot` override
if you need to. Building **on** an arm64 host targets arm64 natively.

---

## Commands

| Command | What it does |
|---|---|
| `emb doctor`  | Host detection (os/arch/distro) + package-backend availability. |
| `emb setup`   | One-shot provision: deps → repos → Flutter SDK → engine, writes `setup_env.sh`. Phases are skippable (`--skip-deps`, …). |
| `emb deps`    | Coalesce host deps across manifests, filter to what's missing, install in one transaction. `--dry-run`, `--yes`. |
| `emb sync`    | Clone/update source repos into `<workspace>/app` (concurrent). |
| `emb flutter` | Clone/checkout the Flutter SDK into `<workspace>/flutter`. |
| `emb engine`  | Fetch prebuilt engine artifacts for `--arch`/`--mode`. `--check` to test availability. |
| `emb aot`     | Build `libapp.so` (profile/release) for an app — the AOT primitive. |
| `emb bundle`  | Build (with `--build`) + assemble an ivi-homescreen bundle. |
| `emb build`   | Build a self-describing package (manifest `build:`) into bundles. |
| `emb env`     | Write `setup_env.sh` (`--print` to stdout). |

Run `emb help <command>` for the full flag list.

---

## Workspace layout

```
<workspace>/                         # $FLUTTER_WORKSPACE
  app/                               # cloned source repos
  flutter/                           # Flutter SDK
  bundle/                            # built bundles (default output)
  setup_env.sh                       # generated env
  .config/flutter_workspace/
    flutter-engine/<commit>/...      # downloaded + extracted engine SDKs
    flutter-engine/bundle-<mode>-<arch>/   # staged engine halves
```

---

## Development

```sh
dart pub get
dart analyze        # very_good_analysis
dart test
```

> Note: the Linux PackageKit backend loads `packagekit_dart`'s native bridge.
> `emb` locates it automatically; set `PK_NC_LIB=/path/to/libpackagekit_nc.so`
> to override.

[license_badge]: https://img.shields.io/badge/license-Apache%202.0-blue.svg
[license_link]: https://opensource.org/licenses/Apache-2.0
[very_good_analysis_badge]: https://img.shields.io/badge/style-very_good_analysis-B22C89.svg
[very_good_analysis_link]: https://pub.dev/packages/very_good_analysis
