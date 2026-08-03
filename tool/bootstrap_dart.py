#!/usr/bin/env python3
"""Fetch and cache the Dart SDK reliably across OSes and distros.

Bootstraps a Dart toolchain without a system package manager -- for installing
or running `emb` on any Linux distro, macOS, or Windows, in CI, or in a minimal
container. Downloads the official SDK archive from Google's dart-archive bucket,
verifies its SHA-256, and extracts it into a content-addressed cache. Re-runs
are a no-op cache hit. Prints the SDK's `bin` directory on stdout; everything
else goes to stderr.

    # Just fetch Dart and put it on PATH:
    DART_BIN=$(python3 tool/bootstrap_dart.py) && export PATH="$DART_BIN:$PATH"

    # Fetch Dart AND install emb from this checkout, in one OS-agnostic step:
    python3 tool/bootstrap_dart.py --install .

    # Install emb AND put Dart + emb on PATH for this shell, in one step:
    eval "$(python3 tool/bootstrap_dart.py --install . --shellenv)"

    # Or install the published package from pub.dev instead of a checkout:
    python3 tool/bootstrap_dart.py --install emb_cli --shellenv

    # Pin a version for reproducible CI:
    python3 tool/bootstrap_dart.py --version 3.10.1

Standard library only -- needs nothing but Python 3.6+.
"""

import argparse
import hashlib
import json
import os
import platform
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import urllib.request
import zipfile

BASE = "https://storage.googleapis.com/dart-archive/channels"

# platform.machine() -> Dart SDK arch token.
ARCH = {
    "x86_64": "x64",
    "amd64": "x64",
    "aarch64": "arm64",
    "arm64": "arm64",
    "armv7l": "arm",
    "armv6l": "arm",
    "riscv64": "riscv64",
}


def log(msg):
    print(msg, file=sys.stderr, flush=True)


def detect_os():
    s = platform.system().lower()
    if s.startswith("linux"):
        return "linux"
    if s == "darwin":
        return "macos"
    if s.startswith("win"):
        return "windows"
    sys.exit("unsupported OS: " + platform.system())


def detect_arch():
    m = platform.machine().lower()
    if m not in ARCH:
        sys.exit("unsupported arch: " + platform.machine())
    return ARCH[m]


def fetch(url, retries=3):
    last = None
    for i in range(retries):
        try:
            with urllib.request.urlopen(url, timeout=60) as r:
                return r.read()
        except Exception as e:  # noqa: BLE001
            last = e
            log("  fetch failed (%d/%d): %s" % (i + 1, retries, e))
    sys.exit("giving up on %s: %s" % (url, last))


def download_to(url, dest, retries=3):
    last = None
    for i in range(retries):
        try:
            with urllib.request.urlopen(url, timeout=120) as r:
                with open(dest, "wb") as f:
                    shutil.copyfileobj(r, f)
            return
        except Exception as e:  # noqa: BLE001
            last = e
            log("  download failed (%d/%d): %s" % (i + 1, retries, e))
    sys.exit("giving up on %s: %s" % (url, last))


def resolve_version(channel, version):
    if version != "latest":
        return version
    meta = json.loads(fetch(BASE + "/%s/release/latest/VERSION" % channel))
    return meta["version"]


def extract_zip(zip_path, dest_dir):
    """Extract, preserving unix modes and symlinks (zipfile drops both)."""
    with zipfile.ZipFile(zip_path) as z:
        for zi in z.infolist():
            mode = (zi.external_attr >> 16) & 0xFFFF
            if stat.S_ISLNK(mode):
                target = os.path.join(dest_dir, zi.filename)
                os.makedirs(os.path.dirname(target), exist_ok=True)
                if os.path.lexists(target):
                    os.remove(target)
                os.symlink(z.read(zi).decode(), target)
                continue
            extracted = z.extract(zi, dest_dir)
            perm = mode & 0o7777
            if perm:
                os.chmod(extracted, perm)


def ensure_sdk(args, version, sdk_root, dart):
    if os.path.exists(dart) and not args.force:
        log("cache hit: Dart %s (%s, %s-%s)"
            % (version, args.channel, args.os, args.arch))
        return

    name = "dartsdk-%s-%s-release.zip" % (args.os, args.arch)
    url = "%s/%s/release/%s/sdk/%s" % (BASE, args.channel, version, name)
    log("fetching Dart %s (%s, %s-%s)"
        % (version, args.channel, args.os, args.arch))

    os.makedirs(args.cache_dir, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=args.cache_dir) as tmp:
        zip_path = os.path.join(tmp, name)
        download_to(url, zip_path)

        want = fetch(url + ".sha256sum").decode().split()[0].strip()
        h = hashlib.sha256()
        with open(zip_path, "rb") as f:
            for chunk in iter(lambda: f.read(1 << 20), b""):
                h.update(chunk)
        if h.hexdigest() != want:
            sys.exit("checksum mismatch: got %s, want %s"
                     % (h.hexdigest(), want))
        log("  sha256 verified")

        staged = os.path.join(tmp, "stage")
        extract_zip(zip_path, staged)  # -> <staged>/dart-sdk/...

        os.makedirs(sdk_root, exist_ok=True)
        final = os.path.join(sdk_root, "dart-sdk")
        if os.path.exists(final):
            shutil.rmtree(final)
        os.replace(os.path.join(staged, "dart-sdk"), final)  # atomic publish
    log("installed: " + sdk_root)


def install_bin_dir(os_name):
    """Where `dart install` places executable shims.

    Mirrors Dart's getDartDataHome('install'): honors $DART_DATA_HOME;
    otherwise Windows uses %LOCALAPPDATA%\\Dart\\install\\bin, macOS uses
    ~/Library/Application Support/Dart/install/bin, and Linux uses
    $XDG_STATE_HOME/Dart/install/bin (or ~/.local/state/Dart/install/bin).
    """
    override = os.environ.get("DART_DATA_HOME")
    if override:
        base = override
    elif os_name == "windows":
        local = os.environ.get("LOCALAPPDATA") or os.path.join(
            os.path.expanduser("~"), "AppData", "Local")
        base = os.path.join(local, "Dart")
    elif os_name == "macos":
        base = os.path.join(os.path.expanduser("~"),
                            "Library", "Application Support", "Dart")
    else:
        state = os.environ.get("XDG_STATE_HOME") or os.path.join(
            os.path.expanduser("~"), ".local", "state")
        base = os.path.join(state, "Dart")
    return os.path.join(base, "install", "bin")


def boards_data_dir(os_name):
    """Where the board library is installed: <data-home>/emb/boards.

    Must agree with resolveBoardsDir() in lib/src/cross/boards_dir.dart --
    these are the two halves of one contract, and a mismatch reads to the user
    as "the install silently did nothing".

    Note this is the *data* home, not the state home install_bin_dir() uses:
    the boards are installed content, and `emb cache gc` must never be able to
    reclaim them.
    """
    if os_name == "windows":
        base = os.environ.get("LOCALAPPDATA") or os.path.join(
            os.path.expanduser("~"), "AppData", "Local")
    elif os_name == "macos":
        base = os.path.join(os.path.expanduser("~"),
                            "Library", "Application Support")
    else:
        base = os.environ.get("XDG_DATA_HOME") or os.path.join(
            os.path.expanduser("~"), ".local", "share")
    return os.path.join(base, "emb", "boards")


def package_version(root):
    """The `packageVersion` constant from lib/src/version.dart, or None."""
    path = os.path.join(root, "lib", "src", "version.dart")
    try:
        with open(path, "r") as f:
            m = re.search(r"packageVersion\s*=\s*'([^']+)'", f.read())
            return m.group(1) if m else None
    except OSError:
        return None


def install_boards(root, os_name):
    """Copy <root>/boards/*.emb.yaml into the data dir, with a version stamp.

    `dart install` AOT-compiles a standalone binary that carries no package
    data files, so boards/ never reaches the installed emb on its own. Without
    this step `extends:` fails for every board.
    """
    src = os.path.join(root, "boards")
    if not os.path.isdir(src):
        log("no boards/ in %s -- skipping board library" % root)
        return
    names = [n for n in sorted(os.listdir(src)) if n.endswith(".emb.yaml")]
    if not names:
        log("boards/ is empty -- skipping board library")
        return

    dst = boards_data_dir(os_name)
    try:
        os.makedirs(dst, exist_ok=True)
        for n in names:
            shutil.copy2(os.path.join(src, n), os.path.join(dst, n))
        version = package_version(root)
        if version:
            with open(os.path.join(dst, ".emb-boards-version"), "w") as f:
                f.write(version + "\n")
    except OSError as e:
        # A failed board copy must not fail the install: emb is usable without
        # boards for everything except `extends:`, and EMB_BOARDS_DIR remains.
        log("WARNING: could not install the board library to %s: %s" % (dst, e))
        return
    log("installed %d board file(s): %s" % (len(names), dst))


def install(dart, bin_dir, target, os_name):
    env = dict(os.environ)
    env["PATH"] = bin_dir + os.pathsep + env.get("PATH", "")
    # A local dir installs from source (abspath -> unambiguously a path);
    # anything else passes through as a pub.dev spec, e.g. `emb` or
    # `emb@^1.0.0` for the published package.
    is_local = os.path.isdir(target)
    if is_local:
        target = os.path.abspath(target)
    log("installing " + target)
    # Keep our stdout clean (only the bin dir) -> send install output to stderr.
    code = subprocess.call([dart, "install", target], env=env,
                           stdout=sys.stderr)
    if code != 0:
        sys.exit("`dart install` failed (%d)" % code)
    if is_local:
        install_boards(target, os_name)
    else:
        # A pub.dev install has no checkout to copy from; `emb boards sync`
        # fetches the library for that path.
        log("installed from pub.dev -- run `emb boards sync` to install the "
            "board library that `extends:` needs")
    log("done. Ensure these are on PATH:\n  %s\n  %s"
        % (bin_dir, install_bin_dir(os_name)))


def main():
    default_cache = os.environ.get("EMB_DART_CACHE") or os.path.join(
        os.environ.get("XDG_CACHE_HOME") or os.path.expanduser("~/.cache"),
        "emb", "dart-sdk")

    ap = argparse.ArgumentParser(
        description="Fetch and cache the Dart SDK (and optionally install emb).")
    ap.add_argument("--version", default="latest",
                    help="SDK version (e.g. 3.10.1) or 'latest' (default).")
    ap.add_argument("--channel", default="stable",
                    choices=["stable", "beta", "dev"])
    ap.add_argument("--os", default=detect_os(),
                    help="Target OS (default: this host).")
    ap.add_argument("--arch", default=detect_arch(),
                    help="Target arch (default: this host).")
    ap.add_argument("--cache-dir", default=default_cache,
                    help="SDK cache root (or set $EMB_DART_CACHE).")
    ap.add_argument("--install", dest="install", metavar="PKG",
                    help="After fetching, run `dart install PKG`: a local "
                         "directory (e.g. '.' for this checkout) or a pub.dev "
                         "spec (e.g. 'emb_cli' or 'emb_cli@^1.0.0').")
    ap.add_argument("--force", action="store_true",
                    help="Re-download even if cached.")
    ap.add_argument("--shellenv", action="store_true",
                    help="Emit an eval-able `export PATH=...` (Dart bin + "
                         "dart-install bin) on stdout instead of just the bin "
                         "dir. Use as: eval \"$(... --shellenv)\".")
    args = ap.parse_args()

    version = resolve_version(args.channel, args.version)
    sdk_root = os.path.join(args.cache_dir, args.channel, version,
                            "%s-%s" % (args.os, args.arch))
    bin_dir = os.path.join(sdk_root, "dart-sdk", "bin")
    dart = os.path.join(bin_dir, "dart.exe" if args.os == "windows" else "dart")

    ensure_sdk(args, version, sdk_root, dart)
    if args.install:
        install(dart, bin_dir, args.install, args.os)
    if args.shellenv:
        # Prepend Dart bin + dart-install bin to PATH. Dart bin first so this
        # SDK wins until a Flutter SDK (sourced from setup_env.sh) is prepended
        # ahead of it. Windows emits PowerShell (`Invoke-Expression`); Unix
        # emits POSIX shell (`eval`). The literal env reference expands in the
        # caller's shell, not here.
        paths = os.pathsep.join([bin_dir, install_bin_dir(args.os)])
        if args.os == "windows":
            print('$env:PATH = "%s%s$env:PATH"' % (paths, os.pathsep))
        else:
            print('export PATH="%s:$PATH"' % paths)
    else:
        print(bin_dir)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
