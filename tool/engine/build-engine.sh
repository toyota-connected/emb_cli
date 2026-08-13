#!/usr/bin/env bash
# build-engine.sh — the single Flutter engine build recipe, shared by emb's
# EngineBuilder, meta-flutter/flutter-engine CI, and a meta-flutter (Yocto)
# recipe.
#
# Usage:
#   build-engine.sh fetch <mode> <arch> <commit> <libc> <out>
#   build-engine.sh build <mode> <arch> <commit> <libc> <out>
#
# Phases mirror the Yocto do_fetch / do_compile split:
#   fetch  — ALL network. depot_tools + `gclient sync` WITH hooks -> <out>: the
#            self-contained engine-src closure that must survive `unshare --net`
#            (clang, sysroot, dart deps, cipd cache, vpython virtualenv).
#   build  — patch -> gn -> ninja -> prepare-sdk; emits <out>/engine-sdk/. With
#            EMB_OFFLINE=1 it must touch no network (never runs `gclient sync`).
#
# Env:
#   EMB_OFFLINE=1        deny network in the build phase (an offline build)
#   EMB_SRC_DIR=<dir>    the fetched closure to build from (build phase)
#   EMB_SYSROOT_DIR=<d>  override --target-sysroot (e.g. OE STAGING_DIR_TARGET)
#   EMB_PATCH_DIR=<dir>  engine patch series, applied in the build phase
#   EMB_PREPARE_DIR=<d>  dir holding prepare-sdk-<arch>.sh (default: this dir)
#   EMB_NO_LTO=1         drop LTO (a memory-constrained validation build)
#   EMB_GN_ARGS=<str>    extra raw gn args (e.g. concurrent_toolchain_jobs=6)
#   EMB_JOBS=<n>         ninja parallelism (default: nproc)
#
# The engine is always built with clang (its own bundled toolchain); the target
# libc is selected by the sysroot + triple, never by the compiler.
set -euo pipefail

# Resolve this script's own directory once, up front: the build phase cd's into
# the engine tree before it needs the co-located prepare-sdk-<arch>.sh, so a
# later `dirname "$0"` would resolve against the wrong cwd.
self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

phase=${1:?phase: fetch|build}
mode=${2:?mode: release|profile|debug}
arch=${3:?arch: x86_64|arm64|armv7hf|riscv64}
commit=${4:?engine commit}
libc=${5:?libc: glibc|musl}
out=${6:?output dir}
jobs=${EMB_JOBS:-$(nproc 2>/dev/null || echo 4)}

# arch -> gn --linux-cpu, dpkg sysroot arch, and the toolchain cpu. The engine's
# gn wrapper expects LLVM-style `<cpu>-unknown-linux-<abi>` triples (even for the
# x86_64 host build), which is what the bundled clang's tool names key off — a
# plain `x86_64-linux-gnu` triple makes it look for a nonexistent `<triple>-ar`.
case "$arch" in
  x86_64)  linux_cpu=x64;     dpkg_arch=amd64;   tcpu=x86_64 ;;
  arm64)   linux_cpu=arm64;   dpkg_arch=arm64;   tcpu=aarch64 ;;
  armv7hf) linux_cpu=arm;     dpkg_arch=armhf;   tcpu=armv7 ;;
  riscv64) linux_cpu=riscv64; dpkg_arch=riscv64; tcpu=riscv64 ;;
  *) echo "build-engine: unknown arch '$arch'" >&2; exit 2 ;;
esac
case "$libc" in
  glibc) abi=gnu ;;
  musl)  abi=musl ;;
  *) echo "build-engine: unsupported libc '$libc' (clang-only; glibc|musl)" >&2; exit 2 ;;
esac
# armv7hf uses the hard-float eabihf ABI suffix.
[ "$arch" = armv7hf ] && abi="${abi}eabihf"
triple="${tcpu}-unknown-linux-${abi}"

log() { printf '[build-engine %s] %s\n' "$phase" "$*" >&2; }

fetch_phase() {
  mkdir -p "$out"
  cd "$out"
  if [ ! -d depot_tools ]; then
    log "cloning depot_tools"
    git clone --depth 1 https://chromium.googlesource.com/chromium/tools/depot_tools.git
  fi
  export PATH="$out/depot_tools:$PATH"
  # Pin to the flutter monorepo; download only the linux target deps.
  gclient config --spec \
    'solutions=[{"managed":False,"name":".","url":"https://github.com/flutter/flutter.git","custom_deps":{},"custom_vars":{"download_android_deps":False,"download_windows_deps":False,"download_linux_deps":True},"deps_file":"DEPS","safesync_url":""}]'
  # HOOKS are essential: they materialise clang, the sysroot, dart deps, the
  # cipd cache and the vpython virtualenv into the closure. Without them the
  # offline build phase would try to fetch and fail.
  log "gclient sync @ $commit (with hooks)"
  gclient sync --force --shallow --no-history -R -D --revision "$commit" -j"$jobs" -v
  log "closure ready at $out"
}

build_phase() {
  local src="${EMB_SRC_DIR:-$out}"
  # Locate the engine build root: a from-scratch gclient (solution name ".")
  # puts it at <closure>/engine/src; some CI layouts nest it under flutter/.
  local eng
  if [ -d "$src/engine/src" ]; then
    eng="$src/engine/src"
  elif [ -d "$src/flutter/engine/src" ]; then
    eng="$src/flutter/engine/src"
  else
    echo "build-engine: no engine src under $src (run the fetch phase first)" >&2
    exit 3
  fi
  cd "$eng"
  export PATH="$src/depot_tools:$PATH"
  [ -d "$src/vpython" ] && export VPYTHON_VIRTUALENV_ROOT="$src/vpython"

  if [ -n "${EMB_OFFLINE:-}" ]; then
    # Belt-and-braces: an offline build must never sync. emb's --offline-strict
    # (and Yocto's do_compile sandbox) enforce this at the process level too.
    export DEPOT_TOOLS_UPDATE=0 CIPD_CACHE_DIR="$src/.cipd" NO_AUTO_UPDATE=1
    log "OFFLINE build (network denied)"
  fi
  if [ -n "${EMB_PATCH_DIR:-}" ]; then
    log "applying patch series from $EMB_PATCH_DIR"
    for p in "$EMB_PATCH_DIR"/*.patch; do [ -e "$p" ] && git apply "$p"; done
  fi

  local outdir="out/linux_${mode}_${linux_cpu}"

  # Sysroot (all targets, x86_64 host included — it also supplies wayland etc.
  # that gn config like ANGLE needs): OE/musl override via EMB_SYSROOT_DIR, else
  # auto-discover the gclient-provided Debian sysroot by its dpkg arch.
  local sysroot="${EMB_SYSROOT_DIR:-}"
  [ -z "$sysroot" ] && sysroot=$(ls -d "$eng"/build/linux/debian_*_"${dpkg_arch}"-sysroot 2>/dev/null | head -n1)
  [ -n "$sysroot" ] && [ -d "$sysroot" ] || {
    echo "build-engine: no sysroot for $arch (dpkg=$dpkg_arch); set EMB_SYSROOT_DIR" >&2
    exit 4
  }
  local clang_root
  clang_root=$(dirname "$(dirname "$(find "$eng/flutter/buildtools" -iname clang++ 2>/dev/null | head -n1)")")

  # The engine's gn linux toolchain compiles with an unprefixed clang but
  # archives/strips with <triple>-{ar,nm,...}; the bundled clang ships only the
  # llvm-* multitools, so provide the prefixed names (llvm-ar acts as ar, etc.).
  local cbin="$clang_root/bin" t
  for t in ar nm objcopy objdump strip ranlib readelf dwp; do
    if [ ! -e "$cbin/${triple}-${t}" ] && [ -e "$cbin/llvm-${t}" ]; then
      ln -sf "llvm-${t}" "$cbin/${triple}-${t}"
    fi
  done

  local -a gnargs=(
    --runtime-mode="$mode" --embedder-for-target --no-build-embedder-examples
    --no-goma --no-rbe --no-stripped --no-enable-unittests
    --no-dart-version-git-info --linux-cpu "$linux_cpu" --target-os linux
    --target-sysroot "$sysroot" --target-toolchain "$clang_root"
    --target-triple "$triple"
  )

  # EMB_NO_LTO makes the release link far lighter (a memory-constrained
  # validation; production keeps LTO). EMB_GN_ARGS injects raw gn args.
  [ -n "${EMB_NO_LTO:-}" ] && gnargs+=(--no-lto)
  [ -n "${EMB_GN_ARGS:-}" ] && gnargs+=(--gn-args="$EMB_GN_ARGS")

  log "gn ($mode/$arch/$libc cpu=$linux_cpu ${EMB_NO_LTO:+ no-lto})"
  ./flutter/tools/gn "${gnargs[@]}"
  ninja -C "$outdir" -j"$jobs"

  # Assemble the engine-sdk/ contract via the co-located prepare-sdk
  # (EMB_PREPARE_DIR overrides). x64's script is prepare-sdk-x86-64.sh (dash).
  local prep_arch="$arch"; [ "$arch" = x86_64 ] && prep_arch=x86-64
  local prep_dir="${EMB_PREPARE_DIR:-$self_dir}"
  local prep="$prep_dir/prepare-sdk-${prep_arch}.sh"
  [ -x "$prep" ] || prep=$(command -v "prepare-sdk-${prep_arch}.sh") || {
    echo "build-engine: prepare-sdk-${prep_arch}.sh not found (set EMB_PREPARE_DIR)" >&2
    exit 5
  }
  log "prepare-sdk -> engine-sdk/"
  "$prep" "$outdir" "$sysroot"
  mkdir -p "$out"
  cp -a "$outdir/engine-sdk/." "$out/engine-sdk/"
  log "engine-sdk staged at $out/engine-sdk"
}

case "$phase" in
  fetch) fetch_phase ;;
  build) build_phase ;;
  *) echo "build-engine: unknown phase '$phase' (fetch|build)" >&2; exit 2 ;;
esac
