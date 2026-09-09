import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Top-level key Flutter stores its device list under.
const customDevicesKey = 'custom-devices';

/// The `custom_devices.json` Flutter reads, resolved exactly as
/// `flutter_tools`' own `Config.managed` does.
///
/// Mirroring upstream matters more than tidiness here: writing to a path
/// Flutter does not read is a silent no-op from the user's point of view. In
/// particular two upstream quirks are reproduced deliberately:
///
/// - A legacy `$HOME/.flutter_custom_devices.json` **wins when it exists**, so
///   emb updates the file a long-lived install is actually reading.
/// - When `XDG_CONFIG_HOME` is set the file is `$XDG_CONFIG_HOME/`
///   `custom_devices.json` — *without* a `flutter/` segment, which only the
///   `$HOME/.config/flutter` fallback carries.
///
/// On Windows the config is always `%APPDATA%\.flutter_custom_devices.json`.
File resolveCustomDevicesConfig({
  Map<String, String>? environment,
  String? operatingSystem,
}) {
  final env = environment ?? Platform.environment;
  final os = operatingSystem ?? Platform.operatingSystem;
  final isWindows = os == 'windows';
  final home = env[isWindows ? 'APPDATA' : 'HOME'] ?? '.';

  final legacy = File(p.join(home, '.flutter_custom_devices.json'));
  if (isWindows) return legacy;
  if (legacy.existsSync()) return legacy;

  final xdg = env['XDG_CONFIG_HOME'];
  final configDir = (xdg != null && xdg.isNotEmpty)
      ? xdg
      : p.join(home, '.config', 'flutter');
  return File(p.join(configDir, 'custom_devices.json'));
}

/// Read the device list from [file]. Returns empty for a missing file, and for
/// one whose JSON is unusable — Flutter treats a malformed managed config as
/// empty rather than deleting it, and so do we.
List<Map<String, dynamic>> readCustomDevices(File file) {
  if (!file.existsSync()) return [];
  try {
    final decoded = jsonDecode(file.readAsStringSync());
    if (decoded is! Map) return [];
    final list = decoded[customDevicesKey];
    if (list is! List) return [];
    return list
        .whereType<Map<dynamic, dynamic>>()
        .map(Map<String, dynamic>.from)
        .toList();
  } on FormatException {
    return [];
  }
}

/// Outcome of a merge: which id landed, and whether it replaced an entry.
class CustomDeviceWrite {
  const CustomDeviceWrite({
    required this.file,
    required this.id,
    required this.replaced,
  });

  final File file;
  final String id;

  /// True when an entry with the same id was already present and was replaced.
  final bool replaced;
}

/// Merge [device] into [file] by its `id`, preserving every other device and
/// any unrelated top-level keys (notably `$schema`).
///
/// Replace-by-id rather than append: re-registering a board after changing its
/// hostname or transport must update the entry Flutter already knows, not
/// leave a stale duplicate that `flutter run -d` can pick instead.
CustomDeviceWrite writeCustomDevice(File file, Map<String, dynamic> device) {
  final id = device['id'] as String;

  Map<String, dynamic> root;
  if (file.existsSync()) {
    try {
      final decoded = jsonDecode(file.readAsStringSync());
      root = decoded is Map ? Map<String, dynamic>.from(decoded) : {};
    } on FormatException {
      root = {};
    }
  } else {
    root = {};
  }

  final existing = readCustomDevices(file);
  final replaced = existing.any((d) => d['id'] == id);
  final merged = [
    for (final d in existing)
      if (d['id'] != id) d,
    device,
  ];

  root[customDevicesKey] = merged;
  file.parent.createSync(recursive: true);
  // Trailing newline + 2-space indent: the shape `flutter custom-devices add`
  // leaves behind, so emb rewriting the file produces no spurious diff.
  file.writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert(root)}\n',
  );
  return CustomDeviceWrite(file: file, id: id, replaced: replaced);
}
