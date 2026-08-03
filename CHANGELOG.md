# Unreleased

- feat: add `--[no-]interactive` to `deps`, `setup`, and `cross`, plus the
  `EMB_NON_INTERACTIVE` environment variable. Interactive is the unconditional
  default; nothing about the environment changes it, and `CI`-style variables
  are deliberately not consulted. Requires `packagekit_dart` 0.4.0, which sends
  the polkit `interactive` hint — without it no `emb deps` could install a
  package on a stock Fedora/openSUSE desktop unless the caller was root or
  covered by a permissive polkit rule.
- feat: decouple `--yes` from interactivity. `--yes` skips emb's own
  confirmation prompt only; `--no-interactive` implies `--yes` because nobody
  is there to answer, but the converse does not hold.
- feat: `brew` sets `NONINTERACTIVE=1` when non-interactive. WinGet accepts the
  flag for interface parity but has no equivalent to apply it to.
- docs: document authorization, including why polkit cannot prompt under WSL
  and the narrowly scoped polkit rule that works there.

# 0.1.1

- fix: locate the PackageKit native bridge (`libpackagekit_nc.so`) when emb is
  installed from pub.dev via `dart install emb_cli`. The code asset ships in the
  `dart install` app-bundle's `lib/` next to the executable; the resolver now
  finds it there (relative to `Platform.resolvedExecutable`). Previously the
  Linux backend reported "packagekit is not available" unless `PK_NC_LIB` or
  `LD_LIBRARY_PATH` was set by hand.

# 0.1.0

Port of `meta-flutter/workspace-automation` to a Dart CLI.

- feat: `emb doctor` — host detection + package-backend availability.
- feat: `emb deps` — coalesce host deps across manifests, filter, install in one
  PackageKit transaction (with `WhatProvides` resolution).
- feat: `emb sync` — concurrent git clone/update into `app/`.
- feat: `emb flutter` — install the Flutter SDK (auto-resolves the engine commit).
- feat: `emb engine` — fetch prebuilt engine artifacts from
  `meta-flutter/flutter-engine` releases (auto fetch-else-build).
- feat: `emb aot` — `create_aot.py` port producing `libapp.so` (profile/release).
- feat: `emb bundle` — assemble an ivi-homescreen bundle (debug JIT / AOT), with
  implicit engine fetch and cross-compile (`x86_64 → arm64/riscv64`).
- feat: `emb build` — manifest-driven build (`build:` block) over an arch × mode
  matrix.
- feat: `emb cross` — resolve a manifest `cross:` block into a toolchain +
  sysroot profile: cross-compile the native embedder for arm64/riscv64 with
  rootless sysroot extraction and Debian `.deb` handling.
- feat: `emb fetch` — fetch a cross target's toolchain + sysroot closure into
  the store: the online acquisition step for an offline build.
- feat: `emb matrix` — render a CI build matrix from manifest `cross:` blocks.
- feat: `emb cache` — inspect and reclaim the shared artifact cache.
- feat: `emb update` — self-update the CLI.
- feat: `emb setup` — one-shot provision; emits `setup_env.sh`.
- feat: `emb env` — write `setup_env.sh`.
- feat: install with `dart install` (Dart 3.10+), or with zero preinstalled
  toolchain via `bootstrap.sh`/`bootstrap.ps1`, which fetch a pinned Dart SDK
  and put `emb` on `PATH` in one step.
- feat: carry native code assets through cross-compiled bundles — stage them
  onto the loader path, build the Linux asset bundle, and accept
  `native_assets.json` for the kernel compile.
- feat: depend on the published `packagekit_dart` `^0.3.2` (hosted, not a path
  dependency).
- feat: auto-resolve the PackageKit native bridge (`libpackagekit_nc.so`) — from
  the package's own build or, for hosted installs, the `package:hooks` build-hook
  output under `.dart_tool/` — so the Linux backend works without `PK_NC_LIB`.
- docs: full per-command reference (every option, default, and value set) in the
  README; add `example/`.

# 0.0.1

- feat: initial commit 🎉
