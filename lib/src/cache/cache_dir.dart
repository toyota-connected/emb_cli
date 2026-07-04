import 'dart:io';

import 'package:path/path.dart' as p;

/// Resolve the shared emb artifact-cache root: `$EMB_CACHE_DIR`, else
/// `$XDG_CACHE_HOME/emb`, else `~/.cache/emb`.
///
/// Modeled on the `EMB_BOARDS_DIR` override pattern. [environment] defaults to
/// the process environment (injectable for tests). The directory is **not**
/// created here — call [ensureCacheDir] for that.
Directory resolveCacheDir({Map<String, String>? environment}) {
  final env = environment ?? Platform.environment;
  final override = env['EMB_CACHE_DIR'];
  if (override != null && override.isNotEmpty) return Directory(override);

  final xdg = env['XDG_CACHE_HOME'];
  if (xdg != null && xdg.isNotEmpty) return Directory(p.join(xdg, 'emb'));

  final home = env['HOME'] ?? env['USERPROFILE'] ?? Directory.systemTemp.path;
  return Directory(p.join(home, '.cache', 'emb'));
}

/// The store-rooted pub cache: `<cache>/pub-cache`. `emb fetch --app`
/// populates it (offline-buildable pub packages) and an offline build points
/// `PUB_CACHE` at it, so pub is part of the same closure the escrow archives.
Directory storePubCacheDir(Directory cacheRoot) =>
    Directory(p.join(cacheRoot.path, 'pub-cache'));

/// [resolveCacheDir], created (with a marker `README`) if absent.
Directory ensureCacheDir({Map<String, String>? environment}) {
  final dir = resolveCacheDir(environment: environment)
    ..createSync(recursive: true);
  final readme = File(p.join(dir.path, 'README'));
  if (!readme.existsSync()) {
    readme.writeAsStringSync(
      'This directory is managed by emb (the Flutter embedder CLI).\n'
      'It holds shared, content-addressed toolchain and engine artifacts.\n'
      'Inspect it with `emb cache list`; reclaim space with `emb cache gc`.\n',
    );
  }
  return dir;
}
