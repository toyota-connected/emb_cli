# emb examples

`emb` is a CLI. Install it, then run the commands below. See the
[top-level README](../README.md) for the full command/flag reference.

```sh
# from the package root
dart pub get
dart install .   # puts `emb` on PATH
# or run without installing:  dart run bin/emb.dart <command>
```

## 1. Inspect the host

```sh
emb doctor
```

```
Host
  os:        linux
  arch:      x86_64 (flutter: x64, engine: x86_64)
  host type: fedora
  version:   43

Package backend
  selected:  packagekit
✓ packagekit is available
✓ 3 updates available
  bash, curl, mesa-libEGL, …
```

## 2. Provision a workspace

Installs host dependencies (one transaction), clones repos, installs the
Flutter SDK, and fetches the prebuilt engine — then writes `setup_env.sh`.

```sh
emb setup --config ../configs --yes
. ./setup_env.sh          # Flutter/Dart on PATH, FLUTTER_WORKSPACE, …
```

Run phases individually if you prefer: `emb deps`, `emb sync`, `emb flutter`,
`emb engine`.

## 3. Build an ivi-homescreen bundle

```sh
# Release AOT bundle for a Raspberry Pi (arm64), cross-compiled from x86_64:
emb bundle --app-path ./app/my_app --arch arm64 --build

# Debug (JIT) bundle for the host:
emb bundle --app-path ./app/my_app --mode debug --build
```

The bundle directory (`data/flutter_assets`, `data/icudtl.dat`,
`lib/libflutter_engine.so`, and `lib/libapp.so` for profile/release) is what
ivi-homescreen runs:

```sh
ivi-homescreen -b <workspace>/bundle/my_app-release-arm64
```

## 4. Self-describing packages

A package that ships an `emb.yaml` (or an `emb:` key in `pubspec.yaml`) builds
itself with no flags:

```sh
emb build ./app/my_app            # builds the manifest's arch × mode matrix
```
