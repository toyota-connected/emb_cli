#!/usr/bin/env sh
# Fetch a cached Dart SDK and install `emb` from this checkout (Linux/macOS).
# All flags pass through, e.g. `./bootstrap.sh --version 3.10.1`.
# Windows: run `python tool\bootstrap_dart.py --activate .` instead.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
exec python3 "$root/tool/bootstrap_dart.py" --activate "$root" "$@"
