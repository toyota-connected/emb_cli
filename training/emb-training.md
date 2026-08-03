---
marp: true
paginate: true
theme: emb
title: "emb — Flutter Embedder CLI · Developer Training (Condensed)"
size: 16:9
---

<!-- _class: lead -->
<!-- _paginate: false -->

# `emb`
## Flutter Embedder CLI — Developer Training

Provision a Flutter **embedded-Linux** workspace and ship deployable app bundles

<div class="subtle">Condensed onboarding — the core workflow end to end</div>

---

## What is `emb`?

`emb` provisions a Flutter **embedded-Linux** workspace and builds deployable
app bundles for embedders such as **ivi-homescreen**. The whole flow:

<div class="flow">

`deps` → `repos` → `Flutter SDK` → `engine` → `AOT` → `ivi-homescreen bundle`

</div>

- One tool for host deps, repos, SDK, engine, AOT, and bundle assembly
- Cross-compiles for **arm64 / riscv64** from an **x86_64** host — *no qemu*
- **Self-describing packages**: a package declares its build in an `emb.yaml`
- A Dart port of `meta-flutter/workspace-automation`

<div class="note">Today: install → provision → build & bundle → cross-compile for a board → reproducible/offline → how ivi-homescreen's CI uses it.</div>

---

## Key vocabulary

| Term | Meaning |
|---|---|
| **Embedder** | The native C/C++ host that runs Flutter on a device (ivi-homescreen) |
| **Engine** | Flutter's C++ runtime — `libflutter_engine.so` + `icudtl.dat` |
| **AOT image** | Your compiled app code — `libapp.so` (release/profile only) |
| **Bundle** | The directory ivi-homescreen consumes: assets + engine + `libapp.so` |
| **Workspace** | The root folder holding `flutter/`, `app/`, `bundle/` |
| **Manifest** | `emb.yaml` — a package describing its own build |

---

<!-- _class: section -->

## 1 · Install & Provision

---

## Install & first run

**Requirements:** `git` on `PATH`; a host package backend (PackageKit / Homebrew /
WinGet). **No preinstalled Dart or Flutter** — `bootstrap` fetches a pinned Dart SDK.

```sh
git clone https://github.com/toyota-connected/emb_cli.git && cd emb_cli
eval "$(./bootstrap.sh --shellenv)"    # emb on PATH; Windows: bootstrap.ps1
emb --version
emb doctor                             # host + package-backend health check
```

<div class="note">Already have Dart ≥ 3.10.1? <code>dart install .</code> puts <code>emb</code> on PATH. Linux native bridge auto-locates; override with <code>PK_NC_LIB=…</code>.</div>

---

## Host packages (Ubuntu / Fedora)

`emb` shells out to host tools, and its Linux PackageKit backend is a **native
bridge compiled at install** — so install by tier.

| Tier | Ubuntu / Debian | Fedora |
|---|---|---|
| **Run emb** — install, provision, build/bundle | `git python3 build-essential cmake ninja-build libsystemd-dev packagekit` | `git python3 gcc gcc-c++ make cmake ninja-build systemd-devel PackageKit` |
| **+ cross** — arm-gnu embedder | `meson pkg-config libwayland-bin tar xz-utils rsync unzip dpkg fdisk e2fsprogs hwdata` | `meson pkgconf-pkg-config wayland-devel tar xz rsync unzip dpkg util-linux e2fsprogs hwdata` |

- **Tier 1** compiles the `libpackagekit_nc.so` bridge (libsystemd + C toolchain + cmake/ninja) so `emb deps` can drive PackageKit — the **daemon must be running**
- **Optional:** `cargo`/`rustc` (Rust) · `rpm`, `opkg-utils`, `flatpak` (packaging) · `openssh` (deploy) · `docker`/`podman` (images) · `oras` (cache OCI, standalone binary)

<div class="note">Downloads use Dart's own HTTPS client (no <code>curl</code>); <code>bootstrap.sh</code> needs only <code>python3</code>. Per-app graphics libs (EGL/Wayland/DRM…) live in <code>emb.yaml</code> and install via <code>emb deps</code> — not here.</div>

---

## Workspace & command map

Root resolves as **`-w` flag → `$FLUTTER_WORKSPACE` → cwd**.

```text
<workspace>/  app/ (repos)  flutter/ (SDK)  bundle/ (output)  setup_env.sh
              .config/flutter_workspace/flutter-engine/<commit>/…
```

| Command | Purpose |
|---|---|
| `setup` | One-shot provision (deps → repos → SDK → engine) |
| `deps`·`sync`·`flutter`·`engine` | The individual provision phases |
| `aot`·`bundle`·`build` | Compile & assemble app bundles |
| `cross`·`fetch`·`matrix` | Cross-compile, offline fetch, CI matrix |
| `cache`·`env`·`update` | Shared store, env script, self-update |

Global: `-v`/`-vv` verbose · `-q` quiet · `--version`.

---

## `emb setup` — provision in one shot

Runs four **skippable** phases → **deps → repos → SDK → engine** → writes `setup_env.sh`.

```sh
emb setup --config ../configs --yes            # everything, no confirmation
emb setup --config ../configs --skip-deps --skip-sync   # SDK + engine only

. ./setup_env.sh                               # load the env it wrote
```

`setup_env.sh` puts the workspace's **Flutter/Dart on `PATH`** and exports
`FLUTTER_WORKSPACE`, `PUB_CACHE`, `XDG_CONFIG_HOME`, and the engine version.

<div class="note">Regenerate it any time with <code>emb env</code> (needed after moving the workspace — the baked path is absolute).</div>

---

## The four phases, individually

| Phase | Command | What it does |
|---|---|---|
| **deps** | `emb deps --dry-run` / `--yes` / `--no-interactive` | Coalesce host deps across manifests, install the **missing** union in one transaction (`WhatProvides`-mapped). `--yes` skips emb's prompt; `--no-interactive` stops the package manager prompting for authorization (CI) |
| **sync** | `emb sync -j 8` | Clone/update source repos into `<workspace>/app` (bounded concurrency) |
| **flutter** | `emb flutter --flutter-version 3.44.2` | Git-clone the SDK into `<workspace>/flutter`; read engine commit |
| **engine** | `emb engine --arch arm64 --mode release` | Fetch prebuilt engine artifacts (auto fetch-else-build) |

```sh
emb flutter -w /tmp/ws1 --flutter-version 3.44.2 && . /tmp/ws1/setup_env.sh
```

<div class="note">Version defaults come from <code>globals.json</code>'s <code>flutter_version</code>. Engine modes you skip are auto-fetched on demand by <code>bundle</code>/<code>build</code>.</div>

---

<!-- _class: section -->

## 2 · Build & Bundle

---

## Modes & architectures

| `--mode` | How it builds | Bundle contents |
|---|---|---|
| `debug` | JIT — `flutter build bundle --debug` | `kernel_blob.bin`, **no** `libapp.so` |
| `profile` / `release` | AOT (`gen_snapshot`) | `libapp.so` (+ engine) |

`--arch` normalizes machine names / Flutter tokens → **`x86_64` · `arm64` ·
`armv7hf` · `riscv64`**.

Cross is **x86_64 host → target arch**: a host-x86_64 **simulator** `gen_snapshot`
emits target code and carries its own loader/libc — **no qemu**.

<div class="note"><code>emb aot</code> accepts only <code>release</code>/<code>profile</code> (debug isn't AOT). <code>bundle</code> takes a single mode; <code>aot</code>/<code>build</code>/<code>engine</code> take many (repeat the flag).</div>

---

## AOT → bundle

**`emb aot`** builds `libapp.so`; **`emb bundle --build`** runs `aot` first, fetches
the engine implicitly, and assembles the bundle ivi-homescreen consumes:

```text
<bundle>/  data/flutter_assets/   data/icudtl.dat
           lib/libflutter_engine.so   lib/libapp.so   # (profile/release)
```

```sh
emb bundle --app-path ./app/my_app --arch arm64   --build              # release
emb bundle --app-path ./app/my_app --arch arm64   --build --mode debug # JIT
emb bundle --app-path ./app/my_app --build                             # host
```

Default output: `<workspace>/bundle/<app>-<mode>-<arch>` — run with
`ivi-homescreen -b <bundle>`.

---

## Self-describing packages — `emb.yaml`

A package with an `emb.yaml` (or `emb:` in `pubspec.yaml`) carries its own build
matrix and host deps, so `emb build` needs no long flag lists.

```yaml
id: my_app
type: app
build:
  app_path: .              # Flutter app dir (default ".")
  archs: [arm64, x86_64]   # target architectures (default: host)
  modes: [release, debug]  # default: [release]
deps:                      # host packages, by OS / distro
  linux: { fedora: [pkg-config, mesa-libEGL-devel], ubuntu: [pkg-config, libegl-dev] }
  macos: [pkg-config, wayland]
```

---

## `emb build` & host deps

```sh
emb build ./app/my_app                              # full manifest matrix
emb build ./app/my_app --arch arm64 --mode release  # override the matrix
emb build ./app/my_app --no-build                   # assemble only
```

**`deps:`** — a **list** under an OS applies to any distro; a **map** under `linux`
selects by distro id. `emb deps` coalesces across all manifests, keeps the
missing, installs the union in one transaction:

```sh
emb deps --packages example --dry-run   # inspect the plan for your host
emb deps --packages example --yes       # install
```

---

## Build ivi-homescreen locally (native `local`)

The native C/C++ embedder builds on **this host** — no Flutter, no cross
toolchain, just host dev libs (EGL, GLES, Wayland, DRM/GBM, …).

```sh
emb deps --packages example --yes                    # host build deps
git clone https://github.com/toyota-connected/ivi-homescreen.git
cp examples/cross/all-backends.emb.yaml ivi-homescreen/
emb cross ivi-homescreen/all-backends.emb.yaml --target local --build
#   one backend only:  --backend wayland-egl
```

Each backend lands at `build-<backend>/shell/homescreen` — six backends:
wayland/drm-kms × egl/vulkan, software, headless-egl.

---

<!-- _class: section -->

## 3 · Cross-compiling for a Board

---

## `emb cross` — the concept

Cross-compile the **native** embedder for `arm64` / `riscv64` from an x86_64 host,
driven by the manifest's `cross:` block. Three **providers**:

| Provider | Sysroot source |
|---|---|
| `arm-gnu` | ARM GNU toolchain + sysroot from a distro image or rsync'd device |
| `yocto-recipe` | a located OE `recipe-sysroot` |
| `yocto-sdk` | a `populate_sdk` install |

**Everything is root-free** — sysroot extracted with `debugfs` / `dpkg-deb`,
`-dev` packages resolved against the image's own apt sources. No `apt`, `chroot`, `sudo`.

---

## The `cross:` block

```yaml
cross:
  provider: arm-gnu
  toolchain_version: 12.3.rel1
  image_url: https://.../raspios-bookworm-arm64-lite.img.xz
  cpu_flags: [-mcpu=cortex-a76]        # pi5
  sysroot:
    dev_packages: [libdrm-dev, libegl-dev, libgbm-dev, libinput-dev]
    snapshot: 2024-06-01               # pin apt to a mirror snapshot (optional)
  augment:                             # libs built from source when sysroot too old
    - { pkg: libdisplay-info, min: "0.2.0", url: https://..., build: meson }
  backends:                            # one build per entry
    drm-kms-egl: { BUILD_BACKEND_DRM_KMS_EGL: 'ON', DISABLE_PLUGINS: 'ON' }
  package: { name: ivi-homescreen, version: 1.0.0, bin: shell/homescreen }
```

---

## `emb cross` — running it

```sh
emb cross ./app/ivi-homescreen --dry-run     # plan only, no side effects
emb cross ./app/ivi-homescreen --build       # toolchain + sysroot + build
emb cross ./app/ivi-homescreen --build --deb # ...and package a root-free .deb
emb cross ./app/ivi-homescreen --clean       # drop build dirs (keep toolchain)
```

| Flag | Effect |
|---|---|
| `--dry-run` / `--json` | Report the resolution plan; no download/build |
| `--build` | Configure + build, one per `cross.backends` entry |
| `--backend <name>` | Build only named backends (repeatable) |
| `--deb` | Package each backend binary (Depends auto-derived) |
| `--clean` / `--clean-all` | Drop build dirs / also toolchain + caches |

<div class="note">Add the global <code>-v</code> (<code>emb -v cross …</code>) to <b>stream the native build output live</b> — cmake configure + ninja/meson compile, prefixed <code>[cmake:…]</code>/<code>[ninja:…]</code>. <code>-vv</code> also logs every command + the resolved cross env.</div>

---

## Deploy a runnable bundle to the board

`--app` builds the Flutter app *and* the embedder into a **runnable bundle**
(embedder + engine + assets + `libapp.so`) — `./homescreen -b .`.

```sh
emb cross . --target rpi5 --build \
  --app ./app/my_app --mode release \
  --deb --tar \
  --deploy pi@raspberrypi.local --run
```

| Flag | Effect |
|---|---|
| `--app <dir>` | Also build this Flutter app → runnable bundle |
| `--deb` / `--tar` | Root-free `.deb` / `.tar.gz` of each bundle |
| `--deploy <user@host>` | rsync (or tar-over-SSH) the bundle to the board |
| `--run` | After deploy, run it over SSH |

---

## Many boards + the board library

Shared config at `cross:` level, per-board overrides under `cross.targets`;
`extends` pulls hardware facts from emb's shipped **board library**:

```yaml
cross:
  provider: arm-gnu
  targets:
    rpi5-bookworm:
      extends: rpi5-bookworm          # ← emb board (triple, image, cpu tuning)
      backends: { drm-kms-egl: { BUILD_BACKEND_DRM_KMS_EGL: 'ON' } }
```

```sh
emb cross . --list-targets
emb cross . --target rpi5-bookworm --build --deb
```

Chain collapses **app ⊕ project ⊕ board**: maps deep-merge; `dev_packages` /
`augment` union; `cpu_flags` / `backends` replace. Boards sharing a sysroot
extract it **once**.

---

<!-- _class: section -->

## 4 · Reproducible & Offline

---

## Reproducible builds — `emb.lock`

A cross resolve pins what it used to **`emb.lock`** (keyed by target) — a moved or
changed URL fails loudly instead of building different bytes.

- **First** resolve → created automatically; **later** → verified, **fails on drift**
- `--update-lock` accepts a change; `--no-verify` skips one run
- `sysroot.snapshot:` pins apt `-dev` versions for the product's life

```sh
emb cross . --target rpi5 --build                # first → writes emb.lock
emb cross . --target rpi5 --build                # later → verifies, fails on drift
emb cross . --target rpi5 --build --update-lock  # accept a change
```

**Commit `emb.lock`** so CI and teammates resolve the same inputs.

---

## Offline builds + the shared cache

Acquisition and building are **separate**: `emb fetch` archives every input while
online; then build with the network **denied**.

```sh
emb fetch . --target rpi5 --app ./app/my_app   # online: toolchain, sysroot, crates, pub
emb cross . --target rpi5 --build --offline     # offline: fail-closed on any miss
emb cross . --target rpi5 --build --offline-strict  # ...sandbox subprocesses too
```

The **`emb cache`** is a content-addressed store shared across workspaces
(`path`·`list`·`gc`·`migrate`·`push`/`pull`·`export`/`import`):

```sh
emb cache export product-lts-2024.tar.zst   # escrow the whole offline closure
emb cache import product-lts-2024.tar.zst   # restore years later, self-verifying
```

<div class="note">CI gate: <code>emb doctor --offline-probe --target rpi5</code> proves the closure is complete before the network is cut. <code>emb cross --dockerfile</code> bakes an OCI toolchain image; <code>emb matrix</code> renders a CI job matrix.</div>

---

<!-- _class: section -->

## 5 · `emb` in CI — ivi-homescreen

---

## How ivi-homescreen adopts `emb`

ivi-homescreen drives **all its Linux builds through `emb`** — the flagship
`pios.yml` cross-compiles for Raspberry Pi; other jobs build natively (`local`).
Every job bootstraps `emb` the same way — **no preinstalled Dart/Flutter**:

```yaml
- name: Fetch emb
  run: git clone --depth 1 https://github.com/toyota-connected/emb_cli.git emb_cli
- name: Build
  run: |
    eval "$(../emb_cli/bootstrap.sh --shellenv)"   # emb on PATH
    emb --version
    emb -v cross . --backend software --build       # native local build
```

<div class="note">The exact same <code>bootstrap.sh --shellenv</code> you'd run locally — CI is not a special path.</div>

---

## Containers — bake the toolchain once

Downloading + extracting the arm-gnu toolchain and sysroot is the **slow** part of a
cold cross build. Bake it into an **OCI image** so CI *pulls* a ready toolchain.

```sh
emb cross . --target rpi5-bookworm --dockerfile        # emit Dockerfile + .dockerignore
emb cross . --target rpi5-bookworm --publish --image <ref> --tag bookworm   # build + push
```

- Bakes toolchain + sysroot + host tools at a **fixed `/emb`** — the path emb computes,
  so a build inside resolves as a **pure cache hit** (`emb cross --build -w /emb`)
- **Content-addressed tag** (`sysroot_key` + toolset): edit the manifest → auto-rebuild;
  unchanged → **skip-on-exists** (a warm `--publish` is a near-no-op)
- `.dockerignore` **slims** the sysroot to headers/libs/pkgconfig + wayland XMLs — 7.4 → 4.7 GB

<div class="note">Two cache layers: the baked <b>image</b> and emb's content-addressed <b>store</b>, mirrored to a registry via <code>emb cache push/pull</code> (oras). arm-gnu only, for now.</div>

---

## `pios.yml` — two phases

Cross-compile **aarch64** on **x86_64 runners** (no emulation) — *resolve once,
build many*:

<div class="flow">

**publish** *(per OS)* → bakes a toolchain image → **build** *(per board × OS × backend)* consumes it

</div>

- **`publish-<os>`** — `emb cross --publish` resolves toolchain + sysroot and pushes
  a **content-addressed** OCI image to GHCR; skips when the image already exists
- **`build-…`** — runs **inside** that image; `emb cross --build -w /emb` is a
  **pure cache hit** on the baked toolchain + sysroot — no per-run fetch

<div class="note">One image per OS serves rpi4 / rpi5 / zero-2w — the sysroot is model-independent.</div>

---

## `pios.yml` — phase 1: publish the image

```yaml
publish:
  strategy: { matrix: { pios: [bookworm, trixie] } }
  steps:
    - run: git clone --depth 1 "$EMB_REPO" emb_cli
    - name: Publish toolchain image (${{ matrix.pios }})
      working-directory: ivi-homescreen
      run: |
        eval "$(../emb_cli/bootstrap.sh --shellenv)"
        emb cross . \
          --target "rpi5-${{ matrix.pios }}" \
          --publish --image "$IMAGE" --tag "${{ matrix.pios }}" \
          -w "$EMB_WS"
```

`--tag <os>` is the stable alias the build matrix consumes; `EMB_CACHE_REGISTRY`
mirrors the resolved store via `oras` so nothing is re-downloaded.

---

## `pios.yml` — phase 2: build in the container

```yaml
build:
  needs: publish
  container:
    image: ghcr.io/.../emb-cross-aarch64-none-linux-gnu:${{ matrix.pios }}
  strategy:
    matrix:
      pios:    [bookworm, trixie]
      board:   [rpi5, rpi4, rpi-zero-2w]
      backend: [wayland-egl, wayland-vulkan, drm-kms-egl, drm-kms-vulkan, software]
  steps:
    - run: |
        eval "$(../emb_cli/bootstrap.sh --shellenv)"
        emb -v cross . --target "${{ matrix.board }}-${{ matrix.pios }}" \
          --build --backend "${{ matrix.backend }}" --no-verify -w /emb
```

**26 build jobs** (board × OS × backend) — each resolves in *seconds* since the
image bakes the toolchain, sysroot, and host tools at `/emb`.

---

## Why this shape works

- **Reproducible** — CI resolves the same toolchain/sysroot bytes as a laptop
  (`emb.lock` + content-addressed store); a drifted URL fails the job loudly
- **Fast** — resolve the toolchain **once** (publish), then N matrix jobs are
  cache hits inside the baked image
- **Portable** — `bootstrap.sh --shellenv` means a runner needs only `git`; no
  Dart/Flutter preinstall, no bespoke setup action
- **DRY** — hardware facts live in emb's board library
  (`ivi-homescreen/.emb/*.emb.yaml` `extends` it); the repo adds only backends + plugins

<div class="note">Same commands locally and in CI — the pipeline is just <code>emb cross</code> with <code>--publish</code> / <code>--build</code>. Native <code>local</code> builds cover integration tests with no toolchain at all.</div>

---

<!-- _class: section -->

## 6 · Wrap-up

---

## End-to-end + hands-on

**The canonical flow (Raspberry Pi, arm64):**
```sh
emb doctor                                              # 0. host + backend
emb setup --config ../configs --yes                     # 1. provision
. ./setup_env.sh                                        # 2. load env
emb bundle --app-path ./app/my_app --arch arm64 --build # 3. release AOT bundle
# 4. run: ivi-homescreen -b <workspace>/bundle/my_app-release-arm64
```

**Try it (works on your x86_64 box via `local`):**
1. `emb doctor` → 2. bootstrap + `emb --version` → 3. `emb deps --packages example --dry-run`
4. `emb cross ivi-homescreen/all-backends.emb.yaml --target local --build --backend wayland-egl`

---

## Troubleshooting & recap

**Tips**
- **See what's happening** → `-v` (live output), `-vv` (every command + env)
- **Plan before doing** → `--dry-run` on `deps`/`cross`; `--json` for machine output
- **Cross preflight** → `emb doctor --target <board> <manifest>`
- **Moved workspace** → `emb env -w <root>` · **Reclaim disk** → `emb cache gc`

**Recap** — `emb` is one tool for the embedded-Linux Flutter flow: `setup`
provisions; `bundle`/`build` produce bundles; `cross` cross-compiles the native
embedder (root-free, no qemu); manifests + board library keep it DRY;
`emb.lock` + `fetch` + `cache` give reproducible, offline builds.

---

<!-- _class: lead -->
<!-- _paginate: false -->

# Thank you

**Resources**
`emb --help` · `emb <cmd> --help` · the repo `README.md`
`examples/cross/` (one manifest per board) · `boards/` (the board library)

<div class="subtle">Questions? Try <code>emb doctor</code> and <code>--dry-run</code> first — they answer most of them.</div>
