import 'package:emb_cli/src/host/host_info.dart';

/// Best-effort, copy-pasteable install command for the missing host [tools].
///
/// This is the *degraded fallback* only — the primary path resolves and (when
/// asked) installs through `HostProvisioner`, which derives real package names
/// from the running backend and so needs no map here. This function exists
/// solely so preflight stays actionable when no provisioner is reachable: a
/// minimal CI container with no PackageKit daemon / native bridge, or the
/// default macOS build (the Homebrew backend is opt-in). It deliberately
/// encodes only the well-known manager prefixes plus the handful of binaries
/// whose package name differs from the command.
///
/// Returns null when the host's package manager is unknown (the caller then
/// omits the line rather than guessing).
String? staticInstallHint(HostInfo host, List<String> tools) {
  final manager = _managerFor(host);
  if (manager == null) return null;
  // Preserve order, drop duplicate package names (e.g. two tools, one package).
  final pkgs = <String>{for (final t in tools) manager.packageFor(t)};
  return '${manager.prefix} ${pkgs.join(' ')}';
}

/// The package managers a static hint can target, with their install prefix.
enum _Manager {
  apt('sudo apt-get install -y'),
  dnf('sudo dnf install -y'),
  zypper('sudo zypper install -y'),
  pacman('sudo pacman -S --needed'),
  apk('sudo apk add'),
  brew('brew install'),
  winget('winget install');

  const _Manager(this.prefix);

  final String prefix;

  /// The package that ships [tool] under this manager. Most binaries share
  /// their package name; only the few that diverge are overridden.
  String packageFor(String tool) {
    switch (tool) {
      case 'xz':
        return this == _Manager.apt ? 'xz-utils' : 'xz';
      case 'pkg-config':
        return switch (this) {
          _Manager.dnf => 'pkgconf-pkg-config',
          _Manager.pacman => 'pkgconf',
          _ => 'pkg-config',
        };
    }
    return tool;
  }
}

/// Map a host to its package manager. Unknown distros return null.
_Manager? _managerFor(HostInfo host) {
  switch (host.os) {
    case HostOs.macos:
      return _Manager.brew;
    case HostOs.windows:
      return _Manager.winget;
    case HostOs.linux:
      return switch (host.hostType) {
        'ubuntu' ||
        'debian' ||
        'linuxmint' ||
        'pop' ||
        'raspbian' ||
        'devuan' ||
        'elementary' => _Manager.apt,
        'fedora' ||
        'rhel' ||
        'centos' ||
        'rocky' ||
        'almalinux' ||
        'ol' ||
        'amzn' => _Manager.dnf,
        'opensuse' ||
        'opensuse-leap' ||
        'opensuse-tumbleweed' ||
        'sles' ||
        'sled' => _Manager.zypper,
        'arch' || 'manjaro' || 'endeavouros' || 'cachyos' => _Manager.pacman,
        'alpine' => _Manager.apk,
        _ => null,
      };
  }
}
