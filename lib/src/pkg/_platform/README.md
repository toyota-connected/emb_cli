# Per-OS provisioner backends

Dart has no OS-conditional dependencies, and conditional imports cannot key on
the operating system. If `emb_cli` depended on `brew_dart` and `winget_dart`
directly, both would have to *compile* on every platform (pulling in
`brew_dart`'s code generation and `winget_dart`'s native build hook even on
Linux).

To keep the default (Linux) build clean, the macOS and Windows backends live
here and are **excluded from analysis** (see `analysis_options.yaml`) and not
imported by the default build, so neither their packages nor their generated
code are required on Linux.

- `brew_provisioner.dart` — macOS / Linux-brew backend (`brew_dart`).
- `winget_provisioner.dart` — Windows backend (`winget_dart`).

## Enabling a backend (building emb on macOS or Windows)

1. Add the dependency to `pubspec.yaml`:
   ```yaml
   # macOS
   brew_dart:
     path: ../app/brew_dart
   # Windows
   winget_dart:
     path: ../app/winget_dart
   ```
   On macOS, also generate `brew_dart`'s code (`dart run build_runner build`
   in that package). On Windows, `winget_dart`'s build hook compiles its native
   bridge automatically.

2. Remove the `lib/src/pkg/_platform/**` exclude from `analysis_options.yaml`.

3. In `host_provisioner.dart`, import the relevant backend and return it from
   `forHost` for that OS instead of throwing `UnsupportedError`.

Both files implement the same `HostProvisioner` interface, so no other code
changes are needed.
