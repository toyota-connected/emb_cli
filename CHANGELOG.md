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
- feat: `emb setup` — one-shot provision; emits `setup_env.sh`.
- feat: `emb env` — write `setup_env.sh`.

# 0.0.1

- feat: initial commit 🎉
