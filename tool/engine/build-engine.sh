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
    # An optional `series` file gives per-patch apply dirs ("<patch> <subdir>",
    # blanks/#comments ignored), mirroring OE's patchdir= — the musl libc++/dart
    # patches live under flutter/third_party. Without a series, patches apply at
    # the engine-src root.
    # Plain `patch`, not `git apply`: engine DEPS pull subtrees like
    # flutter/third_party/dart in as nested git repos that the outer tree
    # ignores, and `git apply` silently refuses to touch files under them. GNU
    # patch has no such boundary. Idempotent: a patch that reverse-applies
    # cleanly is already in, so skip it (safe to re-run / incremental checkout).
    if [ -f "$EMB_PATCH_DIR/series" ]; then
      while read -r pf pdir _; do
        [ -z "$pf" ] && continue
        case "$pf" in \#*) continue ;; esac
        local pd="${pdir:-.}"
        if patch -p1 -d "$pd" -R --dry-run --force \
             < "$EMB_PATCH_DIR/$pf" >/dev/null 2>&1; then
          log "  skip $pf (already applied)"
          continue
        fi
        log "  apply $pf${pdir:+ (in $pdir)}"
        patch -p1 -d "$pd" --force --no-backup-if-mismatch < "$EMB_PATCH_DIR/$pf"
      done < "$EMB_PATCH_DIR/series"
    else
      for p in "$EMB_PATCH_DIR"/*.patch; do
        [ -e "$p" ] || continue
        patch -p1 --force --no-backup-if-mismatch < "$p" || true
      done
    fi
  fi

  # musl target tweaks (mirror meta-flutter's flutter-engine recipe): honor the
  # overridden --target-sysroot instead of the bundled Debian one, and drop the
  # glibc-only mallinfo define swiftshader's vendored LLVM assumes.
  if [ "$libc" = musl ]; then
    log "musl: default-sysroot off + swiftshader mallinfo fix"
    [ -f build/config/sysroot.gni ] && sed -i \
      's|use_default_linux_sysroot = true|use_default_linux_sysroot = false|g' \
      build/config/sysroot.gni
    # swiftshader vendors an LLVM whose Linux config.h assumes glibc — turn off
    # the features musl lacks (mallinfo/mallinfo2, and execinfo.h backtrace) in
    # whichever copy this engine ships (llvm-subzero and/or the older llvm-10.0).
    local ssd='flutter/third_party/swiftshader/third_party'
    for scfg in \
      "$ssd"/llvm-subzero/build/Linux/include/llvm/Config/config.h \
      "$ssd"/llvm-*/configs/linux/include/llvm/Config/config.h; do
      [ -f "$scfg" ] && sed -i -E \
        's@^#define (HAVE_MALLINFO2?|HAVE_BACKTRACE|HAVE_EXECINFO_H) 1$@/* #undef \1 */@' \
        "$scfg"
    done
    # The custom target toolchain (from --target-toolchain) compiles with its own
    # BUILD.gn, which does not pick up extra_cflags_cc — so inject the musl compile
    # defines straight into its commands: tell in-tree libc++ it is on musl (it
    # then selects its native musl locale path, no libc++ patch needed), and force
    # flatbuffers off its locale-independent path (it keys on _XOPEN_VERSION>=700,
    # which musl advertises without providing strtoll_l/strtoull_l). Normalize any
    # prior injection back to the bare anchor first, so re-runs are deterministic.
    ctc='build/toolchain/custom/BUILD.gn'
    if [ -f "$ctc" ]; then
      sed -i -E 's|\$sysroot_flags[^{]* \{\{defines\}\}|$sysroot_flags {{defines}}|g' "$ctc"
      sed -i 's|\$sysroot_flags {{defines}}|$sysroot_flags -D_LIBCPP_HAS_MUSL_LIBC -DFLATBUFFERS_LOCALE_INDEPENDENT=0 {{defines}}|g' "$ctc"
    fi
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

  # musl compiler-rt fallback: the bundled clang ships builtins only for -gnu
  # triples. clang resolves most musl targets to their -gnu builtins, but some
  # (riscv64) find nothing and fail to link; point the missing musl per-target
  # runtime dir at the -gnu one so the builtins/crt resolve.
  if [ "$libc" = musl ]; then
    local gnutriple rtbase
    gnutriple="${triple/musl/gnu}"   # e.g. ...-linux-musl -> ...-linux-gnu
    rtbase=$(ls -d "$clang_root"/lib/clang/*/lib 2>/dev/null | head -n1 || true)
    if [ -n "$rtbase" ] && [ -d "$rtbase/$gnutriple" ] && \
       [ ! -e "$rtbase/$triple" ]; then
      ln -sfn "$gnutriple" "$rtbase/$triple"
    fi
  fi

  local -a gnargs=(
    --runtime-mode="$mode" --embedder-for-target --no-build-embedder-examples
    --disable-desktop-embeddings
    --no-goma --no-rbe --no-stripped --no-enable-unittests
    --no-dart-version-git-info --linux-cpu "$linux_cpu" --target-os linux
    --target-sysroot "$sysroot" --target-toolchain "$clang_root"
    --target-triple "$triple"
  )

  # EMB_NO_LTO makes the release link far lighter (a memory-constrained
  # validation; production keeps LTO).
  [ -n "${EMB_NO_LTO:-}" ] && gnargs+=(--no-lto)

  # musl has no glibc execinfo backtrace. The libc++ musl define is injected into
  # the custom toolchain above (extra_cflags_cc does not reach it). EMB_GN_ARGS
  # passes through any caller-supplied raw gn args.
  [ -n "${EMB_GN_ARGS:-}" ] && gnargs+=(--gn-args="$EMB_GN_ARGS")
  [ "$libc" = musl ] && gnargs+=(--no-backtrace)

  # armv7hf is hard-float: the triple/sysroot are gnueabihf, but gn defaults arm
  # to softfp, which then looks for the hard-float sysroot's nonexistent
  # gnu/stubs-soft.h. Select hard float to match.
  [ "$arch" = armv7hf ] && gnargs+=(--arm-float-abi hard)

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
