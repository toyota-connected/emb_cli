#!/usr/bin/env sh
# Fetch a cached Dart SDK and install `emb` from this checkout (Linux/macOS).
# All flags pass through, e.g. `./bootstrap.sh --version 3.10.1`.
#
# Bare run prints the SDK bin dir on stdout — capture it to put Dart on PATH:
#   DART_BIN=$(./bootstrap.sh) && export PATH="$DART_BIN:$PATH"
# Or emit an eval-able export of both Dart + the emb shim dir in one step:
#   eval "$(./bootstrap.sh --shellenv)"
#
# Windows: run `Invoke-Expression (.\bootstrap.ps1 --shellenv)` instead.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
exec python3 "$root/tool/bootstrap_dart.py" --activate "$root" "$@"
