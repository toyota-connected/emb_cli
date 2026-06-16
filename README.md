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
```

---

### `emb deps`

Coalesce host dependencies across all selected manifests, filter to what's
**missing** on this host, and install the union in **one** transaction.

| Option | Default | Description |
|---|---|---|
| `-c`, `--config <dir>` | `configs` | Legacy JSON config directory. **Repeatable.** |
| `-p`, `--packages <dir>` | — | Directory to discover self-describing `emb` manifests. **Repeatable.** |
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
| `--repos <file>` | — | A JSON file containing a bare array of repo entries. **Repeatable.** |
| `-w`, `--workspace <dir>` | resolution order | Workspace root. |
| `-j`, `--concurrency <n>` | `4` | Maximum concurrent git operations. |

```sh
emb sync --config ../configs -j 8
```

---

### `emb flutter`

Install the Flutter SDK into `<workspace>/flutter`.

| Option | Default | Description |
|---|---|---|
| `-w`, `--workspace <dir>` | resolution order | Workspace root. |
| `--flutter-version <ref>` | `globals.json` `flutter_version` | Version/tag/branch to check out. |
| `-c`, `--config <dir>` | `configs` | Directory to read `globals.json` from. |
| `--configure` | off | Run `flutter config` (desktop + custom devices) and `flutter doctor` after install. |

```sh
emb flutter --flutter-version 3.44.2 --configure
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

### `emb env`

Write `setup_env.sh` (`PATH` for Flutter/Dart, `FLUTTER_WORKSPACE`, `PUB_CACHE`,
`XDG_CONFIG_HOME`, the engine version, …).

| Option | Default | Description |
|---|---|---|
| `-w`, `--workspace <dir>` | resolution order | Workspace root. |
| `-o`, `--output <path>` | `<workspace>/setup_env.sh` | Output file path. |
| `--print` | off | Print to stdout instead of writing a file. |

```sh
emb env                 # write <workspace>/setup_env.sh
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
