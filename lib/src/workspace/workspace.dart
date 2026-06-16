import 'dart:io';

import 'package:path/path.dart' as p;

/// Resolves the Flutter workspace layout `emb` operates on.
///
/// Mirrors the Python tooling's directory conventions:
/// ```text
/// <root>/
///   app/                              # development repositories
///   flutter/                          # Flutter SDK
///   .config/flutter_workspace/<id>/   # per-platform artifacts/cache
/// ```
class Workspace {
  const Workspace(this.root);

  /// Resolve the workspace root from, in order: an explicit [override], the
  /// `FLUTTER_WORKSPACE` environment variable, or [fallback] (defaults to the
  /// current working directory).
  factory Workspace.resolve({String? override, Directory? fallback}) {
    final envPath = Platform.environment['FLUTTER_WORKSPACE'];
    final path = override ??
        (envPath != null && envPath.isNotEmpty ? envPath : null) ??
        (fallback ?? Directory.current).path;
    return Workspace(Directory(p.normalize(p.absolute(path))));
  }

  /// The workspace root directory.
  final Directory root;

  /// `<root>/app` — where source repositories are cloned.
  Directory get appDir => Directory(p.join(root.path, 'app'));

  /// `<root>/flutter` — the Flutter SDK clone.
  Directory get flutterDir => Directory(p.join(root.path, 'flutter'));

  /// `<root>/.config/flutter_workspace/<id>` — per-platform working dir.
  /// Mirrors `get_platform_working_dir`.
  Directory platformDir(String id) =>
      Directory(p.join(root.path, '.config', 'flutter_workspace', id));

  /// Create [appDir] (and the root) if missing, returning it.
  Directory ensureAppDir() {
    appDir.createSync(recursive: true);
    return appDir;
  }

  /// Create and return [platformDir] for [id].
  Directory ensurePlatformDir(String id) {
    return platformDir(id)..createSync(recursive: true);
  }

  /// The Flutter engine commit, read from
  /// `<root>/flutter/bin/internal/engine.version`. Mirrors
  /// `get_flutter_engine_version` / `get_flutter_engine_commit`. Returns null
  /// when the SDK (or the file) is absent.
  String? engineCommit() {
    final f =
        File(p.join(flutterDir.path, 'bin', 'internal', 'engine.version'));
    if (!f.existsSync()) return null;
    final v = f.readAsStringSync().trim();
    return v.isEmpty ? null : v;
  }

  /// Whether this is a Flutter "mono repo" SDK (an `engine/` folder exists in
  /// the SDK). Mirrors the `MONO_REPO` detection in
  /// `get_flutter_engine_version`.
  bool get isMonoRepo =>
      Directory(p.join(flutterDir.path, 'engine')).existsSync();

  @override
  String toString() => 'Workspace(${root.path})';
}
