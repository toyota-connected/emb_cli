# emb engine *builder* image (produce) — flutter-engine CI only.
# glibc base (NOT Alpine: the engine
# clang, CIPD tools, and gen_snapshot are glibc x86_64 binaries). Bakes
# depot_tools + gn/ninja/vpython prereqs + a Dart SDK + emb, at a fixed /emb.
#
# podman build -f tool/engine/Dockerfile.builder -t emb-engine-builder .
# podman run --rm -v "$EMB_CACHE_DIR:$EMB_CACHE_DIR" -w /emb emb-engine-builder \
# emb engine --build --arch arm64 --mode release --exec-native -w /emb
FROM debian:bookworm-slim

ARG EMB_REPO=https://github.com/toyota-connected/emb_cli.git
ARG EMB_REF=main
ENV DEBIAN_FRONTEND=noninteractive

# Build tooling for the engine + the augment rebuild + sysroot extraction.
RUN apt-get update && apt-get install -y --no-install-recommends \
 git curl ca-certificates python3 python3-venv \
 xz-utils tar rsync unzip fdisk e2fsprogs dpkg \
 build-essential cmake ninja-build meson pkg-config hwdata \
 libwayland-bin \
 && rm -rf /var/lib/apt/lists/*

# depot_tools (gclient, the gn wrapper, ninja) on PATH.
RUN git clone --depth 1 \
 https://chromium.googlesource.com/chromium/tools/depot_tools.git \
 /opt/depot_tools
ENV PATH="/opt/depot_tools:${PATH}"
ENV DEPOT_TOOLS_UPDATE=0

# emb + a pinned Dart SDK via bootstrap; persist both on the default PATH so
# later layers and `podman run` find them (bootstrap's shellenv is per-shell).
RUN git clone --depth 1 --branch "${EMB_REF}" "${EMB_REPO}" /opt/emb_cli \
 && cd /opt/emb_cli \
 && eval "$(python3 tool/bootstrap_dart.py --install . --shellenv)" \
 && ln -sf "$(command -v dart)" /usr/local/bin/dart \
 && ln -sf "$(command -v emb)" /usr/local/bin/emb \
 && emb --version

ENV FLUTTER_WORKSPACE=/emb
WORKDIR /emb
