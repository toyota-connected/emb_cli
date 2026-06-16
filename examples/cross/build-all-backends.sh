#!/usr/bin/env bash
# Build every ivi-homescreen backend natively on this machine.
#
#   build-all-backends.sh <ivi-homescreen-dir> [extra emb args...]
#
# e.g.  build-all-backends.sh ~/workspace-automation/app/ivi-homescreen
#       build-all-backends.sh ~/.../ivi-homescreen --backend drm-kms-egl
#       build-all-backends.sh ~/.../ivi-homescreen --deb
#
# Needs the host -dev libs (drm, gbm, egl, gles2, libinput, xkbcommon, seat,
# udev, libdisplay-info >= 0.2.0, wayland + wayland-protocols, vulkan) and `emb`
# on PATH.
set -euo pipefail

src="${1:?usage: build-all-backends.sh <ivi-homescreen-dir> [emb args...]}"
shift
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# `emb cross <file>` uses the file's parent dir as the CMake source, so drop the
# manifest next to the source first.
cp "$here/all-backends.emb.yaml" "$src/all-backends.emb.yaml"
emb cross "$src/all-backends.emb.yaml" --target local --build "$@"
