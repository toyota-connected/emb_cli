#!/usr/bin/env bash
# Build every ivi-homescreen backend natively on this machine.
#
#   build-all-backends.sh <ivi-homescreen-dir> [extra emb args...]
#
# e.g.  build-all-backends.sh ~/workspace-automation/app/ivi-homescreen
#       build-all-backends.sh ~/.../ivi-homescreen --backend drm-kms-egl
#       build-all-backends.sh ~/.../ivi-homescreen --deb
#
# Runs THIS checkout's emb via `dart run` (so it works on a feature branch
# before `emb` is re-installed). Once `emb` is activated from this branch you
# can use it directly, or set EMB=emb here. Needs the host -dev libs (drm, gbm,
# egl, gles2, libinput, xkbcommon, seat, udev, libdisplay-info >= 0.2.0, wayland
# + wayland-protocols, vulkan).
set -euo pipefail

src="${1:?usage: build-all-backends.sh <ivi-homescreen-dir> [emb args...]}"
shift
src="$(cd "$src" && pwd)"                          # absolutize the source dir
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"                   # emb_cli repo root
manifest="$src/all-backends.emb.yaml"

# `emb cross <file>` uses the file's parent dir as the CMake source, so drop the
# manifest next to the source first.
cp "$here/all-backends.emb.yaml" "$manifest"

if [[ -n "${EMB:-}" ]]; then
  read -r -a emb <<<"$EMB"
else
  emb=(dart run "$root/bin/emb.dart")
fi
"${emb[@]}" cross "$manifest" --target local --build "$@"
