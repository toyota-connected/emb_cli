import 'dart:ffi' show Abi;
import 'dart:io';

/// The high level operating system family `emb` runs on.
///
/// This mirrors the Python tool's `get_host_type()` which collapses the host
/// to `linux`, `darwin` or `windows`.
enum HostOs {
  linux,
  macos,
  windows;

  /// The token used by config files in `supported_host_types` for the
  /// non-Linux operating systems. On Linux the distro id is used instead
  /// (see [HostInfo.hostType]).
  String get configToken => switch (this) {
        HostOs.linux => 'linux',
        HostOs.macos => 'darwin',
        HostOs.windows => 'windows',
      };
}

/// Immutable description of the machine `emb` is executing on.
///
/// Ports `get_host_type`, `get_freedesktop_os_release_*`,
/// `get_host_machine_arch`, `get_flutter_arch`, `get_darwin_major_version`
/// and `get_windows_major_version` from the Python `flutter_workspace.py`
/// / `common.py` tooling.
class HostInfo {
  const HostInfo({
    required this.os,
    required this.machineArch,
    required this.archAliases,
    required this.hostType,
    required this.versionId,
    this.prettyName,
  });

  /// Detect the current host. Reads `/etc/os-release` on Linux.
  factory HostInfo.detect() {
    final os = _detectOs();
    final machineArch = _machineArch(os);
    final archAliases = _archAliases(machineArch);

    switch (os) {
      case HostOs.linux:
        final rel = _readOsRelease(File('/etc/os-release'));
        return HostInfo(
          os: os,
          machineArch: machineArch,
          archAliases: archAliases,
          hostType: (rel['ID'] ?? '').toLowerCase().trim(),
          versionId: (rel['VERSION_ID'] ?? '').trim(),
          prettyName: rel['PRETTY_NAME'],
        );
      case HostOs.macos:
        return HostInfo(
          os: os,
          machineArch: machineArch,
          archAliases: archAliases,
          hostType: 'darwin',
          versionId: _macMajorVersion(),
        );
      case HostOs.windows:
        return HostInfo(
          os: os,
          machineArch: machineArch,
          archAliases: archAliases,
          hostType: 'windows',
          versionId: _windowsMajorVersion(),
        );
    }
  }

  /// Operating system family.
  final HostOs os;

  /// Raw `uname -m`-equivalent machine architecture, e.g. `x86_64`,
  /// `aarch64`, `arm64`, `AMD64`, `ARM64`, `riscv64`.
  final String machineArch;

  /// The set of architecture tokens that should be treated as equivalent to
  /// [machineArch] when matching a config's `supported_archs` / per-arch
  /// `pre-requisites` keys (config files mix `x86_64`/`x64` and
  /// `aarch64`/`arm64`).
  final Set<String> archAliases;

  /// The token matched against a config's `supported_host_types`.
  ///
  /// On Linux this is the `/etc/os-release` `ID` (e.g. `fedora`, `ubuntu`);
  /// on macOS it is `darwin`; on Windows it is `windows`. Mirrors
  /// `is_host_type_supported`.
  final String hostType;

  /// The host OS version token: `/etc/os-release` `VERSION_ID` on Linux, the
  /// Darwin major version on macOS, or the Windows major version.
  final String versionId;

  /// `/etc/os-release` `PRETTY_NAME` when available (Linux only).
  final String? prettyName;

  /// The Flutter/Google architecture token (`x64`, `arm64`, `aarch64`).
  /// Mirrors `get_flutter_arch`.
  String get flutterArch => switch (machineArch) {
        'x86_64' || 'AMD64' || 'x64' => 'x64',
        'arm64' || 'ARM64' => 'arm64',
        'aarch64' => 'arm64',
        _ => machineArch,
      };

  /// Whether any of [archs] matches this host's architecture.
  bool supportsArch(Iterable<String> archs) =>
      archs.any((a) => archAliases.contains(a.toLowerCase()));

  /// Whether any of [hostTypes] matches this host. Mirrors
  /// `is_host_type_supported`.
  bool matchesHostType(Iterable<String> hostTypes) =>
      hostTypes.map((h) => h.toLowerCase()).contains(hostType);

  static HostOs _detectOs() {
    if (Platform.isLinux) return HostOs.linux;
    if (Platform.isMacOS) return HostOs.macos;
    if (Platform.isWindows) return HostOs.windows;
    throw UnsupportedError(
        'Unsupported host operating system: ${Platform.operatingSystem}');
  }

  /// Map the FFI [Abi] to the raw machine string the config files use. This
  /// avoids shelling out to `uname`.
  static String _machineArch(HostOs os) {
    final abi = Abi.current();
    if (abi == Abi.linuxX64) return 'x86_64';
    if (abi == Abi.linuxArm64) return 'aarch64';
    if (abi == Abi.linuxRiscv64) return 'riscv64';
    if (abi == Abi.macosX64) return 'x86_64';
    if (abi == Abi.macosArm64) return 'arm64';
    if (abi == Abi.windowsX64) return 'AMD64';
    if (abi == Abi.windowsArm64) return 'ARM64';
    // Fall back to the raw ABI name for anything unexpected.
    return abi.toString();
  }

  static Set<String> _archAliases(String machineArch) {
    switch (machineArch.toLowerCase()) {
      case 'x86_64':
      case 'amd64':
      case 'x64':
        return {'x86_64', 'amd64', 'x64'};
      case 'arm64':
      case 'aarch64':
        return {'arm64', 'aarch64'};
      case 'riscv64':
        return {'riscv64'};
      default:
        return {machineArch.toLowerCase()};
    }
  }

  /// Parse a freedesktop `os-release` file into a map. Public for testing.
  /// Mirrors `get_freedesktop_os_release`.
  static Map<String, String> _readOsRelease(File file) {
    if (!file.existsSync()) return const {};
    return parseOsRelease(file.readAsStringSync());
  }

  static String _macMajorVersion() {
    // `sw_vers -productVersion` yields e.g. "14.5"; take the major.
    try {
      final r = Process.runSync('sw_vers', ['-productVersion']);
      final v = (r.stdout as String).trim();
      final major = v.split('.').first;
      if (major.isNotEmpty) return major;
    } on ProcessException {
      // ignore — fall through
    }
    return '';
  }

  static String _windowsMajorVersion() {
    // Platform.operatingSystemVersion is like
    // '"Windows 10 Pro" 10.0 (Build 22631)'. Extract the leading major.
    final v = Platform.operatingSystemVersion;
    final m = RegExp(r'(\d+)\.\d+').firstMatch(v);
    return m?.group(1) ?? '';
  }

  @override
  String toString() => 'HostInfo(os: ${os.name}, arch: $machineArch, '
      'hostType: $hostType, versionId: $versionId)';
}

/// Parse the contents of a freedesktop `os-release` file into key/value pairs,
/// stripping surrounding quotes. Mirrors `get_freedesktop_os_release`.
Map<String, String> parseOsRelease(String contents) {
  final out = <String, String>{};
  for (final raw in contents.split('\n')) {
    final line = raw.trim();
    if (!line.contains('=')) continue;
    final idx = line.indexOf('=');
    final key = line.substring(0, idx).trim();
    var value = line.substring(idx + 1).trim();
    if (value.length >= 2 &&
        ((value.startsWith('"') && value.endsWith('"')) ||
            (value.startsWith("'") && value.endsWith("'")))) {
      value = value.substring(1, value.length - 1);
    }
    out[key] = value;
  }
  return out;
}
