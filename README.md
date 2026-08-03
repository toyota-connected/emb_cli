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

- **Host dependency install** in one transaction (PackageKit on Linux, Homebrew
  on macOS, WinGet on Windows), with `WhatProvides` resolution so `pkg-config`,
  `libjpeg-devel`, etc. just work.
- **Prebuilt Flutter engine** fetched from
  [meta-flutter/flutter-engine](https://github.com/meta-flutter/flutter-engine)
  releases (auto, keyed by the SDK's engine commit).
- **Cross-compile AOT** for `arm64` / `riscv64` from an `x86_64` host using the
  engine's simulator `gen_snapshot` — no qemu (the artifact is self-contained).
- **Self-describing packages**: a package declares its build in a manifest and
  `emb build <dir>` does the rest.

---

## Requirements

- **Dart SDK ≥ 3.10.1** to run/build `emb` — or none preinstalled: `bootstrap.sh`
  (Linux/macOS) or `bootstrap.ps1` (Windows) fetches a pinned SDK (see
  [Install](#install)).
- **Python 3.6+** for the bootstrap script.
- **Linux**: PackageKit for host dependency install (dnf/apt/zypper).
- **macOS**: Homebrew for host dependency install.
- **Windows**: WinGet for host dependency install (Windows 10 1809+).
- `git` on `PATH`.
- Cross-compiling to a device arch is supported **from an x86_64 host**.

### Authorization

Installing host packages on Linux is gated by polkit. On a stock desktop the
relevant actions are `auth_admin_keep`, so a non-root `emb deps` must be
authorized before the daemon will act. By default `emb` asks the daemon to
prompt you, and on a normal desktop session that is all you need.

Where a prompt cannot be shown — no polkit agent, no logind session, or WSL
(see below) — the transaction fails immediately with a not-authorized error.
Two ways to fix that:

**Preferred: authorize the actions you need.** Keeps `emb` unprivileged, which
is the arrangement PackageKit exists to make possible.

```javascript
// /etc/polkit-1/rules.d/49-emb-packagekit.rules
//
// Scoped to three named actions on purpose. A blanket grant on
// org.freedesktop.packagekit.* would also cover repository reconfiguration
// and untrusted-package installs, which is a considerably larger grant.
polkit.addRule(function(action, subject) {
    var allowed = [
        "org.freedesktop.packagekit.package-install",
        "org.freedesktop.packagekit.package-remove",
        "org.freedesktop.packagekit.system-update"
    ];
    // "wheel" on Fedora/RHEL/Arch, "sudo" on Debian/Ubuntu.
    if (allowed.indexOf(action.id) !== -1 &&
        (subject.isInGroup("wheel") || subject.isInGroup("sudo"))) {
        return polkit.Result.YES;
    }
});
```

This is a persistent change to system authorization policy: it grants
unattended install, remove, and update to every local administrator, with no
authentication. Decide whether that is acceptable for your machine. Remove it
with `sudo rm /etc/polkit-1/rules.d/49-emb-packagekit.rules`.

**Escape hatch: run as root.** Works anywhere, but `emb` keeps caches and
configuration under `$HOME`, and running as root leaves root-owned files there
that you can no longer modify. Prefer the rule for anything repeated. Note that
`sudo` resets `PATH`, so an `emb` installed under `~/.local` needs an absolute
path:

```sh
sudo "$(command -v emb)" deps --config ../configs --no-interactive
```

#### CI

Two separate things, and conflating them is the usual cause of a confusing CI
failure:

- **Suppress the prompt.** Pass `--no-interactive`, or set
  `EMB_NON_INTERACTIVE=1` once at the workflow `env:` level. Nothing is
  inferred from `CI`, `GITHUB_ACTIONS` or similar — the mode must be stated.
- **Be authorized.** Non-interactive suppresses the prompt; it does not grant
  anything. Without authorization the run still fails, just faster and with a
  clearer message.

On GitHub-hosted runners the steps run as a non-root user with passwordless
sudo and no logind session, so a prompt could never be answered. Install the
rule above in a setup step — that keeps the CI path identical to the developer
path. Running the whole job under `sudo` also works, but leaves root-owned
files in the runner's home.

In containers you are usually already root and there is often no polkit daemon
— frequently no PackageKit at all. Provisioning with the distro package
manager directly (`apt-get install …`) is the right thing there, and is what
this repository's own workflows do for their build dependencies.

#### WSL

polkit cannot reliably prompt under WSL. It needs a logind session owned by
the calling user, and WSL often supplies neither — shells started by tooling
belong to no session at all, and sessions created via `sudo` are owned by root
while running your uid. In both cases an authentication agent registers and is
then never consulted, so the install fails instantly with a not-authorized
error that looks exactly like a real denial.

Install the polkit rule above. It needs no agent, no session, and no password,
and it works from any shell. To check whether a session is the problem:

```sh
loginctl show-session $(loginctl session-status | head -1 | awk '{print $1}') \
    -p User -p Service -p Class
```

A usable session reports your own uid, `Service=login`, and `Class=user`. If
the command errors, the shell has no session and can never be prompted.

### Host packages (Linux)

`emb` shells out to a handful of host tools, and its Linux host-dependency
backend (PackageKit) is a **native bridge compiled at install time**. What you
need depends on which emb features you use — install by tier.

> Downloads inside emb use Dart's own HTTPS client (**not** `curl`/`wget`), and
> `bootstrap.sh` needs only `python3` (stdlib). The Dart SDK, Flutter SDK, and
> ARM GNU toolchain are fetched by emb — they are not distro packages.

**Tier 1 — install & run emb** (`setup`, `deps`, `sync`, `flutter`, `bundle`,
`build`). Installing the package pulls in the PackageKit native bridge
(`libpackagekit_nc.so`), which compiles vendored `sdbus-cpp` — so it needs
libsystemd headers, a C/C++ toolchain, `cmake`, and `ninja`. Without them
`emb deps`/`doctor` silently can't drive PackageKit. `git` clones repos and the
Flutter SDK; the **PackageKit daemon** must be running for host-dep install.

```sh
# Ubuntu / Debian  (add the PackageKit daemon: `packagekit`)
sudo apt-get install -y git python3 build-essential cmake ninja-build \
  pkg-config libsystemd-dev packagekit
# Fedora  (PackageKit is usually already present)
sudo dnf install -y git python3 gcc gcc-c++ make cmake ninja-build \
  pkgconfig systemd-devel PackageKit
```

> Already have Dart ≥ 3.10.1? Drop `python3` (it is only for `bootstrap.sh`).
> `git-lfs` is additionally needed only for repos that carry Git-LFS assets.

**Tier 2 — cross-compile the native embedder** (`emb cross`, `arm-gnu`
provider). Adds the embedder's C/C++ build tools plus the root-free sysroot
extraction + Debian `.deb` handling chain: `sfdisk`+`debugfs` keep sysroot
extraction rootless (else it falls back to `sudo losetup`), `dpkg-deb` extracts
the sysroot's `-dev` packages, and `hwdata` is needed to rebuild the
`libdisplay-info` augment.

```sh
# Ubuntu / Debian
sudo apt-get install -y meson pkg-config libwayland-bin \
  tar xz-utils rsync unzip dpkg fdisk e2fsprogs hwdata
# Fedora
sudo dnf install -y meson pkgconf-pkg-config wayland-devel \
  tar xz rsync unzip dpkg util-linux e2fsprogs hwdata
```

> Per-app graphics/build libraries (EGL, GLES, Wayland, DRM/GBM, …) are **not**
> listed here — a package's `emb.yaml` declares them and `emb deps` installs
> them for your distro. `libwayland-bin` / `wayland-devel` here is only for the
> `wayland-scanner` codegen the embedder build itself runs.

**Tier 3 — optional feature add-ons**

| Feature | Tool(s) | Ubuntu / Debian | Fedora |
|---|---|---|---|
| Rust (`build: cargo`) modules | `cargo`, `rustc`, `rustup` | `cargo rustc` (or rustup) | `cargo rust` (or rustup) |
| `.rpm` packaging (`--rpm`) | `rpmbuild` | `rpm` | `rpm-build` |
| `.ipk` packaging (`--ipk`) | `opkg-build` | `opkg-utils` † | `opkg-utils` † |
| `.flatpak` packaging (`--flatpak`) | `flatpak`, `flatpak-builder` | `flatpak flatpak-builder` | `flatpak flatpak-builder` |
| Deploy over SSH (`--deploy` / `--run`) | `ssh`, `scp`, `rsync` | `openssh-client rsync` | `openssh-clients rsync` |
| Toolchain images (`--dockerfile` / `--publish`) | `docker` or `podman` (+ `skopeo`) | `docker.io` or `podman` | `podman` |
| Cache OCI (`cache push` / `pull`) | `oras` | download the static binary † | download the static binary † |
| `--offline-strict` sandbox | `unshare` | `util-linux` (preinstalled) | `util-linux-core` (preinstalled) |
| Build launchers (optional) | `ccache` / `sccache` | `ccache` | `ccache` |

† Not in the default distro repos: `opkg-utils` may need EPEL or a source build;
`oras` is a standalone release binary from [oras.land](https://oras.land).

---

## Install

Quickest path — **no preinstalled Dart or Flutter needed**. The bootstrap script
fetches a pinned Dart SDK and activates `emb`; `--shellenv` prints the
shell-specific PATH update for the current session.

### Linux / macOS

```sh
git clone https://github.com/toyota-connected/emb_cli.git && cd emb_cli
eval "$(./bootstrap.sh --shellenv)"
emb --version
```

### Windows (PowerShell)

```powershell
git clone https://github.com/toyota-connected/emb_cli.git; cd emb_cli
Invoke-Expression (.\bootstrap.ps1 --shellenv)
emb --version
```

A `bootstrap.cmd` wrapper is also provided for CMD users (does not support
`--shellenv`; manually add the printed bin directories to `PATH`).

### From an existing Dart SDK

```sh
# From the package root:
dart pub get
dart install .   # puts `emb` on PATH

emb --help
```

Make sure the `dart install` bin dir (`~/.local/state/Dart/install/bin` on
Linux, `~/Library/Application Support/Dart/install/bin` on macOS,
`%LOCALAPPDATA%\Dart\install\bin` on Windows) is on `PATH`. You can also run
without installing:

```sh
dart run bin/emb.dart <command>     # from the package root
```

> The Linux backend loads `packagekit_dart`'s native bridge
> (`libpackagekit_nc.so`). `emb` locates it automatically — from the package's
> own build, or from the `package:hooks` build-hook output under
> `.dart_tool/`. Override with `PK_NC_LIB=/path/to/libpackagekit_nc.so`.

---

## Build ivi-homescreen locally

The native C/C++ embedder builds on **this host** — no Flutter, no cross
toolchain, just host dev libraries (EGL, GLES, Wayland, DRM/GBM, libinput,
xkbcommon, …; the [`example/ivi-homescreen`](example/ivi-homescreen/emb.yaml)
manifest declares the set per distro, and
[`examples/cross/`](examples/cross/) lists the full per-backend deps). It uses
the built-in **`local`** target (host compiler + system libraries).

```sh
# 1. Install host build deps (PackageKit on Linux, brew on macOS).
emb deps --packages example --yes            # or --dry-run to preview

# 2. Build the embedder natively. `emb cross <file>` uses the file's parent as
#    the CMake source, so drop the backend-matrix manifest next to the source.
git clone https://github.com/toyota-connected/ivi-homescreen.git
cp examples/cross/all-backends.emb.yaml ivi-homescreen/
emb cross ivi-homescreen/all-backends.emb.yaml --target local --build
#   one backend only:  --backend wayland-egl
```

Each backend lands at `build-<backend>/shell/homescreen`. Validated on Fedora —
all six backends build to distinct host (x86-64) ELF binaries:

| backend | | backend | |
|---|---|---|---|
| `wayland-egl` | ✅ | `drm-kms-vulkan` | ✅ |
| `wayland-vulkan` | ✅ | `software` | ✅ |
| `drm-kms-egl` | ✅ | `headless-egl` | ✅ |

(Vulkan backends additionally need the Vulkan loader/headers; DRM backends need
libdisplay-info ≥ 0.2.0, libseat, libxcursor.) Cross-compile the same backends
for a device with `--target <board>` — see [`examples/cross/`](examples/cross/).

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
#    ivi-homescreen -b <workspace>/bundle/my_app-release-arm64
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
| `--version` | Print the CLI version. |
| `-v`, `--verbose` | Stream toolchain output live, prefixed per step (`[cmake:…]`, `[ninja:…]`). |
| `-vv` | Everything `-v` does, plus diagnostic logging (every shell command, resolved env). |
| `-q`, `--quiet` | Errors only; suppress progress and info logging. |

Verbosity may also be set with `EMB_VERBOSITY=0\|1\|2` (used when no flag is
passed). Note `--version` is long-only — `-v` now means verbose.

`--workspace` (`-w`), shown on most commands, follows the resolution order
above. `--mode`/`--arch` defaults and value sets differ **per command** — see
each entry.

---

### `emb doctor`

Report host detection (os / arch / distro), package-manager backend
availability, and — when the backend can report it (PackageKit) — the count of
available package updates (from the backend's last cache refresh; `doctor` is
read-only and doesn't refresh). Exit code is non-zero if the backend is
unavailable; the update check never fails the command. `--json` emits a
machine-readable `{schema, command, ok, data}` envelope instead of text.

It also reports whether you are **authorized** to install host packages. A
reachable backend is not the same as a usable one: `doctor`'s other checks
exercise only read-only operations, which need no authorization, so a green
backend line previously said nothing about whether `emb deps` could actually
install anything. The authorization line distinguishes *already authorized*
(a polkit rule or cached authorization covers you), *needs authentication*
(you will be prompted — or cannot be, if this shell has no login session), and
*refused by policy*. The probe never prompts, so running `doctor` cannot pop an
authentication dialog as a side effect. When `pkcheck` is absent it reports
`unknown` rather than failing. See [Authorization](#authorization).

With `--target <name>` it instead reports a cross target's **provider
preflight** — the host tools that target's provider needs (e.g. `tar`/`xz`/
`rsync` for arm-gnu), each present or missing, with an install hint — resolving
the manifest at the positional path (default: the current directory). Exit code
is non-zero when a required tool is missing.

With `--offline-probe --target <name>` it **certifies the target's
[offline build closure](#offline-builds)** is materialized: it resolves the
toolchain + sysroot from the store with the network denied, confirms each cargo
module is vendored, and (under `--strict`) that network isolation is available.
No build runs — it checks inputs only, so it stays a seconds-scale gate for CI
to run after `emb fetch`. Exit code is non-zero (with the fix, `emb fetch`) when
anything is missing.

```sh
emb doctor
emb doctor --json | jq .data.backend
emb doctor --target rpi5-bookworm examples/cross/pi5.emb.yaml
emb doctor --target rpi5-bookworm . --json | jq .data.target.preflight
emb doctor --offline-probe --target rpi5 .          # is the closure ready for an offline build?
emb doctor --offline-probe --strict --target rpi5 . --json | jq .data.offline_probe
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
| `-y`, `--yes` | off | Skip the deps confirmation prompt. |
| `--[no-]interactive` | on | Allow the system package manager to prompt for authorization during the deps step. `--no-interactive` implies `--yes`. See [Authorization](#authorization). |
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
| `-y`, `--yes` | off | Skip the confirmation prompt. |
| `--[no-]interactive` | on | Allow the system package manager to prompt for authorization. `--no-interactive` implies `--yes`. |

```sh
emb deps --config ../configs --dry-run          # plan only
emb deps --config ../configs --yes              # install in one transaction
emb deps --config ../configs --no-interactive   # unattended; never prompts
```

`--yes` and `--interactive` are independent. `--yes` skips **emb's own**
confirmation; `--interactive` governs whether the *system package manager* may
prompt you to authenticate. `--no-interactive` implies `--yes` because nobody
is there to answer, but the converse does not hold — `--yes` still allows an
authorization prompt.

Interactive is the default in every context. Nothing about the environment
changes it: `CI`, `GITHUB_ACTIONS` and similar variables are deliberately not
consulted, because a mode that depends on ambient state is invisible in the
command you typed. Set `EMB_NON_INTERACTIVE=1` to opt out once for a wrapper
or a workflow-level `env:` block; an explicit `--interactive` still overrides
it.

Non-interactive is not an authorization mechanism. It suppresses the prompt; it
does not grant anything. See [Authorization](#authorization) for how to
actually be authorized.

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

#### Host dependencies (`deps:`)

The `deps:` block declares host build packages, keyed by **OS**, then optionally
by **distro id** on Linux:

- A **list** directly under an OS (`macos: [...]`, `windows: [...]`, or
  `linux: [...]`) applies to **any** distro on that OS.
- A **map** under `linux` (`fedora: [...]`, `ubuntu: [...]`, …) selects by the
  host's distro id (from `/etc/os-release`, what `emb doctor` prints).

`emb deps` coalesces these across every selected manifest, filters to what's
**missing** on the current host, and installs the union in one transaction
(PackageKit on Linux, brew on macOS). Resolution is by package *name*, mapped to
the backend's real package via `WhatProvides`, so e.g. `pkg-config` resolves
even where the package is `pkgconf`.

A complete worked manifest (ivi-homescreen graphics deps for fedora/ubuntu/macOS)
is in [`example/ivi-homescreen/emb.yaml`](example/ivi-homescreen/emb.yaml).
Inspect the resolved/missing plan for your host without installing:

```sh
emb deps --packages example --dry-run
```

> Legacy `configs/*.json` declare deps differently — as inline
> `sudo … install` strings under `runtime.pre-requisites[arch][distro][version]`
> — from which `emb` extracts the package names. Both schemas normalize to the
> same per-host rule set.

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
| `--json` | off | Emit the plan as a machine-readable `{schema, command, ok, data}` envelope instead of text (implies `--dry-run`). Also on `emb doctor`. |
| `--prepare` | off | After resolving, build the `augment` libraries into the overlay. |
| `--build` | off | Configure + build the embedder under the resolved profile, one build per `cross.backends` entry. |
| `--backend <name>` | all | Build only the named `cross.backends` entries. Repeatable. |
| `--deb` | off | With `--build`: package each backend binary into a root-free `.deb` (Depends auto-derived from the binary's needed libraries). |
| `--app <dir>` | — | With `--build`: also build this Flutter app for the target and assemble a **runnable bundle** (embedder + engine + flutter_assets + icudtl + libapp), runnable as `./homescreen -b .`. |
| `-m`, `--mode <mode>` | `release` | Runtime mode for the `--app` bundle (`debug`/`profile`/`release`). |
| `--tar` | off | Also produce a `.tar.gz` of each runnable bundle. |
| `--deploy <user@host>` | — | With `--app`: send each runnable bundle to the board over SSH — rsync when the target has it, else a tar-over-SSH fallback (port/opts reused from `cross.sysroot` when device-sourced). |
| `--deploy-dir <path>` | `ivi-homescreen` | Remote destination dir for `--deploy`. |
| `--run` | off | After `--deploy`, run the bundle on the target over SSH (`./homescreen -b .`). |
| `--clean` | off | Remove this target's build + overlay dirs (keeps the toolchain + sysroot), then exit. |
| `--clean-all` | off | Also remove the downloaded / extracted toolchain + sysroot and the apt / deb caches, then exit. |
| `--update-lock` | off | Regenerate this target's `emb.lock` entry from the resolved toolchain/sysroot (accepts an intentional URL / version change). See [Reproducible builds](#reproducible-builds-emblock). |
| `--no-verify` | off | Skip `emb.lock` verification for this resolve (don't fail on a drifted artifact sha or version). |
| `--fetch-only` | off | Resolve and materialize the toolchain + sysroot closure (and pin `emb.lock`), then stop before configuring or building — the online acquisition step. Same work as [`emb fetch`](#emb-fetch). See [Offline builds](#offline-builds). |
| `--offline` | off | Deny all network access: reuse already-cached toolchain/sysroot inputs and fail on a miss (run `--fetch-only` online first). Cargo modules build against their vendored crates (`CARGO_HOME`/`CARGO_NET_OFFLINE`). See [Offline builds](#offline-builds). |
| `--offline-strict` | off | Like `--offline`, but also run build subprocesses inside a network namespace, and **refuse to build** when that isolation is unavailable instead of degrading to input-level denial. See [Offline builds](#offline-builds). |
| `--host-tools` | off | With `--build`: use the host's `cmake`/`meson` instead of the SDK's, for OE SDKs that pin an old one (e.g. AGL ships cmake 3.16.5). The OE env + toolchain/cross file are unchanged. Also set via `cross.host_build_tools`. |
| `--install-deps` | off | Install the provider's missing preflight host tools via the host package backend (PackageKit/brew) instead of erroring. Opt-in; needs privileges. Falls back to printing the manual install command when no backend is reachable. |
| `--[no-]interactive` | on | Allow the system package manager to prompt for authorization when `--install-deps` is used. See [Authorization](#authorization). |
| `--dockerfile` | off | Resolve, then emit a `Dockerfile` + `.dockerignore` (into the platform dir) that bake the toolchain + sysroot into an OCI image so CI pulls instead of resolving. arm-gnu only; does not build. See [Toolchain images](#toolchain-images). |

```sh
emb cross ./app/ivi-homescreen --dry-run      # plan only, no side effects
emb cross ./app/ivi-homescreen --build        # toolchain + sysroot + build
emb -v cross ./app/ivi-homescreen --build     # ...streaming the native build output
emb cross ./app/ivi-homescreen --build --deb  # ...and package a .deb
emb cross ./app/ivi-homescreen --clean        # drop build dirs (keep toolchain)
emb cross ./app/ivi-homescreen --clean-all    # drop everything for this target
```

> **Seeing the build.** By default `--build` prints step progress only. Add the
> global `-v` (`emb -v cross …`) to **stream the native toolchain output live** —
> the cmake configure and the ninja/meson compile, line-prefixed per step
> (`[cmake:…]`, `[ninja:…]`) — which is the fastest way to diagnose a failing
> embedder build. `-vv` additionally logs every shell command and the resolved
> cross environment (toolchain, sysroot, flags). Being a global flag, `-v` goes
> **before** `cross`.

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
    snapshot: 2024-06-01          # pin apt resolution to a mirror snapshot (optional)
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

#### Layered manifests: `extends` (board → project → app)

emb ships a **board library** — hardware/OS definitions for known boards under
its own `boards/` directory (e.g. `rpi5-bookworm`: triple, toolchain version,
sysroot image, partition, cpu tuning, the base GUI stack). A manifest pulls one
in with `cross.extends` so a project never re-spells hardware facts:

```yaml
# ivi-homescreen/.emb/raspberry-pi.emb.yaml — the PROJECT layer
cross:
  targets:
    rpi5-bookworm:
      extends: rpi5-bookworm          # ← emb board (hardware/OS)
      backends: { drm-kms-egl: { BUILD_BACKEND_DRM_KMS_EGL: 'ON' } }
      augment:  [ { pkg: libdisplay-info, min: "0.2.0", build: meson } ]
      sysroot:  { dev_packages: [ libgstreamer1.0-dev ] }   # added to the board's
```

`extends` takes two forms:

| Form | Resolves to |
|---|---|
| `<board>` | a target in emb's board library (the **hardware** layer) |
| `<dir>#<target>` | a target in another emb project at `<dir>` (the **project** layer) |

The second form lets an **app** build on a project (e.g. ivi-homescreen) and add
only what is app-specific — typically **plugin configuration**, which depends on
the plugins the app ships, not on the embedder or the board:

```yaml
# my-flutter-app/.emb/app.emb.yaml — the APP layer
#   (ivi-homescreen checked out alongside the app)
cross:
  targets:
    rpi5-bookworm:
      extends: '../ivi-homescreen#rpi5-bookworm'   # ← project target (→ board)
      defines: { DISABLE_PLUGINS: 'OFF', PLUGINS_DIR: '../ivi-homescreen-plugins/plugins' }
      sysroot: { dev_packages: [ libnl-3-dev ] }
```

The chain collapses **app ⊕ project ⊕ board** with the same merge rules at every
layer: nested maps deep-merge; `cpu_flags` and `backends` **replace** (each is a
complete statement); `sysroot.dev_packages` and `augment` **union** (each layer
adds to the stack below it; an `augment` entry for a `pkg` already present
replaces it). `<dir>` is resolved relative to the extending manifest's project
root (the `.emb/` parent, else the file's directory); cross-project reference
cycles are rejected. The board library location can be overridden with
`EMB_BOARDS_DIR` (it otherwise ships with emb).

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
| `arm-gnu` | sha256 of the toolchain tarball and the distro image (byte-exact); the resolved `-dev` package versions + digests; a device-sourced sysroot records provenance only — a live host can't be content-pinned. |
| `yocto-sdk` | `OECORE_SDK_VERSION`, plus the sha256 of the `populate_sdk` installer when fetched from `sdk_url`. |
| `yocto-recipe` | the located recipe version + the native gcc version (it downloads nothing, so there is no artifact to sha). |

The lock also records a root `env:` block — the host tool versions the resolve
ran with (`emb`, the engine and Flutter commits, `rustc`) — so a rebuild years
later can tell whether a difference came from a changed tool rather than a
changed input.

Drift is reported for: a changed artifact sha (moved URL), a changed `-dev`
package version, a changed resolved / derived version, or edited manifest inputs
(the content-addressed `sysroot_key` / `build_key`). An artifact not re-fetched
on a warm cache is skipped, so verification fires exactly when bytes are
re-materialized.

**Apt snapshots.** By default `dev_packages` resolve against the live mirror, so
the same names can pull different versions over time. Set `sysroot.snapshot:` to
a date (`2024-06-01`, or a full `YYYYMMDDTHHMMSSZ` stamp) to pin resolution to a
[snapshot.debian.org](https://snapshot.debian.org) / snapshot.raspbian.org
mirror, so a build resolves the same `-dev` versions for the life of the
product. The date folds into the sysroot store key, so changing it re-extracts;
a source with no known snapshot service warns and falls back to the live mirror.

```sh
emb cross . --target rpi5 --build                 # first run → writes emb.lock
emb cross . --target rpi5 --build                 # later → verifies, fails on drift
emb cross . --target rpi5 --build --update-lock    # accept an intentional change
```

> Note: `emb.lock` lives at the project root. A `.emb/` project keys its entries
> by target name (unique across the project). A **flat single-file manifest**
> keys its entry by `<manifest-stem>:<target>`, so several loosely co-located
> `*.emb.yaml` sharing one directory get independent entries in the shared
> `emb.lock` instead of clobbering one another.

#### Offline builds

Acquisition and building are separate: fetch every input once while online,
then build with the network denied. This is what a long-support-window product
needs — a build that never asks the network for anything it didn't already
archive.

- [`emb fetch <project> [--target <t>] [--app <dir>]`](#emb-fetch) (or
  `emb cross … --fetch-only`) resolves and materializes the toolchain + sysroot
  closure — including the apt `-dev` set — into the shared store and pins
  `emb.lock`. It also vendors each `build: cargo` module's crates
  (`cargo vendor --locked`, keyed by its `Cargo.lock`) into the store, and with
  `--app` runs `flutter pub get --enforce-lockfile` into a store-rooted
  `PUB_CACHE`. Then it stops. Everything now lives under the shared cache, so
  one [`emb cache export`](#emb-cache) escrows the whole closure.
- `emb cross … --build --offline` then builds with all network access denied:
  the content store serves a cached blob or fails closed rather than
  downloading, the apt path refuses to reach out, cargo modules build against
  the vendored crates (`CARGO_HOME` → vendor dir, `CARGO_NET_OFFLINE`,
  `--offline`), and the app's `flutter build bundle` reads from the same
  store-rooted `PUB_CACHE` — so nothing touches a registry. A miss names the
  missing artifact and points you back at the fetch step.

`--offline` denies emb's own egress and fast-fails cargo, but trusts a build
subprocess to honor it. `--offline-strict` additionally runs build subprocesses
inside a rootless network namespace (`unshare --net`, loopback only), so a build
script that reaches for the network is denied outright — and it **refuses to
build** when that isolation is unavailable (common on locked-down CI runners and
inside containers where unprivileged user namespaces are disabled) rather than
silently falling back to the weaker guarantee.

```sh
emb fetch . --target rpi5 --app ./app/my_app        # online: toolchain, sysroot, crates, pub
emb cross . --target rpi5 --build --offline          # offline: build, no network
emb cross . --target rpi5 --build --offline-strict    # ...and sandbox build subprocesses
```

Pin `dev_packages` with `sysroot.snapshot:` (above) so the offline build resolves
the same package versions every time. In CI, gate on
[`emb doctor --offline-probe`](#emb-doctor) after the fetch step to prove the
closure is complete before the network is cut. To keep the closure for the long
haul, [`emb cache export`](#emb-cache) writes it to a single self-verifying
`.tar.zst` that `emb cache import` restores on another machine or years later.

#### Toolchain images

Downloading + extracting an arm-gnu toolchain and sysroot is the slow part of a
cold build. `--dockerfile` resolves the target, then emits a `Dockerfile` +
`.dockerignore` into the platform dir that bake the toolchain + sysroot into an
OCI image (with the host build tools — cmake, ninja, wayland-scanner, …) — so CI
pulls a ready toolchain instead of re-resolving:

```sh
emb cross . --target rpi5 --dockerfile
# Wrote …/cross-aarch64-none-linux-gnu-<key>/Dockerfile
# Build:  docker build -t emb-cross-aarch64-none-linux-gnu:<key> …/cross-…-<key>
docker build -t emb-cross-aarch64-none-linux-gnu:<key> <that dir>
```

The image bakes them at a fixed workspace (`/emb`) under the same
`cross-<triple>-<key>` path emb computes, so consuming it needs **no special
flag** — a build in the image resolves as a cache hit:

```yaml
# CI: run the cross build against the prebuilt image
container: emb-cross-aarch64-none-linux-gnu:<key>
# → emb cross <manifest> --target rpi5 --build -w /emb   (skips download/extract)
```

To run the same build locally (no CI), mount your project, pub cache, and Dart
SDK into the image — only the toolchain + sysroot are baked, emb itself is not:

```sh
docker run --rm \
  --security-opt label=disable \    # Fedora/SELinux only; omit elsewhere
  -v "$PROJECT:$PROJECT" -v "$PUB_CACHE:$PUB_CACHE" -v "$DART_SDK:$DART_SDK:ro" \
  -e "PATH=$DART_SDK/bin:$PATH" -e "PUB_CACHE=$PUB_CACHE" -w "$PROJECT" \
  emb-cross-aarch64-none-linux-gnu:<key> \
  emb cross "$PROJECT" --target rpi5 --build --backend wayland-egl -w /emb
```

The `<key>` (the `sysroot_key`) must match the manifest; change the manifest and
you rebuild the image. Always (re)build the image from the **current** emitter —
it bakes the host build tools the embedder needs (cmake, ninja, meson,
`wayland-scanner`, git/curl); an older image is missing them. `augment`
libraries aren't baked — `--build` rebuilds them into the cached sysroot at
consume time (cheap). arm-gnu only for now.

The baked sysroot is slimmed to a cross-build sysroot via `.dockerignore`: the
device rootfs's runtime data, bundled apps, docs, kernel/firmware, and target
executables are dropped, keeping headers, libraries, pkgconfig/cmake metadata,
and the wayland protocol XMLs. (For the radxa zero3 image this took the sysroot
from 7.4 GB to 4.7 GB — image ~6 GB — with all three backends still building.)

---

### `emb fetch`

Materialize a cross target's toolchain + sysroot closure into the shared store
and pin `emb.lock`, then stop — the online acquisition step for an
[offline build](#offline-builds). It resolves the toolchain + sysroot (no
configure/build), vendors each `build: cargo` module's crates, and with
`--app` prefetches the app's pub packages — so `emb cross … --build --offline`
afterwards needs no network. Native (`local`/`host`) targets skip the toolchain
resolve but still vendor crates and prefetch pub.

```sh
emb fetch <project-dir|manifest.yaml> [options]
```

| Option | Default | Description |
|---|---|---|
| `<project-dir\|manifest>` | **mandatory (positional)** | Project dir or manifest file (same resolution as `emb cross`). |
| `-t`, `--target <name>` | manifest default | Target to fetch; a `cross.targets` entry or a per-board `.emb/` file. |
| `-w`, `--workspace <dir>` | resolution order | Workspace root. |
| `--app <dir>` | — | Also prefetch this Flutter app's pub packages (`flutter pub get --enforce-lockfile`) into the store-rooted `PUB_CACHE`, so they are part of the offline closure the escrow archives. |
| `--update-lock` | off | Regenerate this target's `emb.lock` entry from the resolved toolchain/sysroot. |
| `--no-verify` | off | Skip `emb.lock` verification for this resolve. |

```sh
emb fetch . --target rpi5 --app ./app/my_app  # toolchain + sysroot + crates + pub
emb cross . --target rpi5 --build --offline    # then build with no network
```

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

### `emb cache`

Inspect and reclaim the shared artifact cache — a content-addressed store of
toolchain and engine artifacts, downloaded once per machine and shared across
every workspace and target. Location resolves as `$EMB_CACHE_DIR`, else
`$XDG_CACHE_HOME/emb`, else `~/.cache/emb`.

| Subcommand | Description |
|---|---|
| `path` | Print the resolved cache directory. |
| `list [--json]` | List store entries (kind, key, size, live references). |
| `gc [--dry-run]` | Remove incomplete entries and unreferenced, stale ones; report space reclaimed. |
| `migrate [-w <ws>] [--dry-run]` | Adopt a workspace's existing toolchain/engine trees into the store (moved in place of a re-download), leaving symlinks behind. |
| `push [<kind>/<key> …] --registry <r> [--repo <r>] [--force] [--dry-run] [--json]` | Upload store entries to an OCI registry as artifacts (via `oras`), so a team/CI shares prebuilt trees. Defaults to every complete entry; skips refs that already exist unless `--force`. |
| `pull <kind>/<key> … --registry <r> [--repo <r>] [--link <dir>] [--json]` | Download named entries from the registry into the store (extract-staged like a local build); `--link` also symlinks each into `<dir>`. |
| `export <archive.tar.zst> [--cas-only] [--image <ref>]` | Package the offline build closure (content-addressed blobs, extracted trees, apt `-dev` set, vendored crates, pub packages) into one deterministic `.tar.zst` escrow archive. `--cas-only` keeps just the blobs (~half the size; trees re-extract on an offline resolve). `--image` pins the build-environment image (from `emb cross --dockerfile`) in the manifest — use a digest ref. See [Offline builds](#offline-builds). |
| `import <archive.tar.zst> [--json]` | Restore an escrow archive into the cache, merging with what's there (content-addressed entries are identical, so overlap is safe); reports the pinned build-environment image, if any. |

The OCI registry (`push`/`pull`) is the *live* mirror under your control; an
escrow archive (`export`/`import`) is the *offline* copy — a single file you own
that reconstructs the closure years later, self-verifying on restore because its
blobs are content-addressed. The archive is *data*, though — years on it still
needs a runnable environment (emb, the Flutter SDK, a period-appropriate host).
Pin that with `--image <ref>@sha256:…`, a container image emb can emit via
[`emb cross --dockerfile`](#toolchain-images), so the escrow references the
environment that reconstructs the closure, not just the bytes.

`push`/`pull` speak to an OCI registry through `oras` (one static binary on
Linux/macOS/Windows, no daemon). Set the registry with `--registry` or
`$EMB_CACHE_REGISTRY` and authenticate beforehand with `oras login` (it reuses
`~/.docker/config.json`). The ref for an entry is
`<registry>/<repo>:<kind>-<key>` (repo defaults to `emb-cache`). Entry keys are
identity-based, so a puller must name the exact `<kind>/<key>` (from `emb cache
list` on the producer, or a prior resolve).

```sh
emb cache path
emb cache list --json | jq '.data.entries'
emb cache gc --dry-run
emb cache migrate --dry-run          # preview adoptions for the current workspace
oras login ghcr.io                   # once, to authenticate
emb cache push --registry ghcr.io/acme --dry-run   # preview refs
emb cache pull toolchain/arm-gnu-12.3.rel1-x86_64-aarch64-none-linux-gnu \
  --registry ghcr.io/acme
emb cache export product-lts-2024.tar.zst    # escrow the whole offline closure
emb cache import product-lts-2024.tar.zst    # ...restore it on another machine
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

All three host-package backends (PackageKit, Homebrew, WinGet) are compiled into
every build. Each package's native build hook no-ops on unsupported platforms.

[license_badge]: https://img.shields.io/badge/license-Apache%202.0-blue.svg
[license_link]: https://opensource.org/licenses/Apache-2.0
[very_good_analysis_badge]: https://img.shields.io/badge/style-very_good_analysis-B22C89.svg
[very_good_analysis_link]: https://pub.dev/packages/very_good_analysis
