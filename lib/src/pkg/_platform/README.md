# Per-OS provisioner backends

Each file implements the `HostProvisioner` interface for one platform's package
manager. All three backends are compiled into every build — their underlying
packages (`packagekit_dart`, `brew_dart`, `winget_dart`) gracefully no-op their
native build hooks on unsupported platforms.

- `brew_provisioner.dart` — macOS / Linux-brew backend (`brew_dart`).
- `winget_provisioner.dart` — Windows backend (`winget_dart`).

The Linux backend (`PackageKitProvisioner`) lives in `../packagekit_provisioner.dart`.

`HostProvisioner.forHost()` selects the correct backend at runtime based on
`HostInfo.os`.
