import 'dart:io';

import 'package:path/path.dart' as p;

/// Name of the stamp file written beside an installed board library.
///
/// Holds the `packageVersion` that installed it, so a board library left
/// behind by an older emb can be reported rather than silently trusted.
const boardsVersionStamp = '.emb-boards-version';

/// Resolve the installed board-library directory: `$EMB_BOARDS_DIR`, else the
/// per-OS data home.
///
/// Data home rather than cache home on purpose: `emb cache gc` must never be
/// able to delete the board library, and unlike the artifact cache it is not
/// content-addressed or reconstructible from the network.
///
/// [environment] and [operatingSystem] default to the running process
/// (injectable for tests). The directory is **not** created here — the
/// installer writes it, mirroring `resolveCacheDir`'s contract.
Directory resolveBoardsDir({
  Map<String, String>? environment,
  String? operatingSystem,
}) {
  final env = environment ?? Platform.environment;
  final override = env['EMB_BOARDS_DIR'];
  if (override != null && override.isNotEmpty) return Directory(override);
  return Directory(
    p.join(
      dataHomeDir(environment: env, operatingSystem: operatingSystem).path,
      'emb',
      'boards',
    ),
  );
}

/// The per-OS user data home, matching what `tool/bootstrap_dart.py` uses so
/// the Python installer and this resolver agree on one location.
///
/// Data home is deliberately distinct from cache home: contents are installed
/// state, not reclaimable artifacts.
Directory dataHomeDir({
  Map<String, String>? environment,
  String? operatingSystem,
}) {
  final env = environment ?? Platform.environment;
  final os = operatingSystem ?? Platform.operatingSystem;

  if (os == 'windows') {
    final local = env['LOCALAPPDATA'];
    if (local != null && local.isNotEmpty) return Directory(local);
    final profile = env['USERPROFILE'];
    if (profile != null && profile.isNotEmpty) {
      return Directory(p.join(profile, 'AppData', 'Local'));
    }
    return Directory(Directory.systemTemp.path);
  }

  final home = env['HOME'] ?? env['USERPROFILE'] ?? Directory.systemTemp.path;

  if (os == 'macos') {
    return Directory(p.join(home, 'Library', 'Application Support'));
  }

  // Linux and everything else: XDG.
  final xdg = env['XDG_DATA_HOME'];
  if (xdg != null && xdg.isNotEmpty) return Directory(xdg);
  return Directory(p.join(home, '.local', 'share'));
}

/// The version stamp written beside an installed board library, or null when
/// absent — which is legitimate for a hand-maintained `EMB_BOARDS_DIR`.
String? readBoardsStamp(Directory boards) {
  final f = File(p.join(boards.path, boardsVersionStamp));
  if (!f.existsSync()) return null;
  final v = f.readAsStringSync().trim();
  return v.isEmpty ? null : v;
}
