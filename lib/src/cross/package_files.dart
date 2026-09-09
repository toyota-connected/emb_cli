import 'dart:io';

import 'package:path/path.dart' as p;

/// One `cross.package.files` entry after path resolution: an absolute host
/// `src`, the absolute target `dest`, and the manifest's explicit `mode`
/// (null to take each file's own mode).
typedef PackageFileEntry = ({String src, String dest, String? mode});

/// The concrete files a `files:` block contributes once directory sources are
/// expanded: host source → target dest, host source → octal mode, and any
/// diagnostics the caller should surface.
typedef PackageFiles = ({
  Map<String, String> files,
  Map<String, String> modes,
  List<String> warnings,
});

/// Expand [entries] into the concrete files to stage.
///
/// A source naming a **directory** contributes every file beneath it, at
/// `<dest>/<path relative to the source>`. This is what makes a Flutter bundle
/// packageable: `data/flutter_assets` is hundreds of files, regenerated on
/// every build, so no hand-written list stays correct. A source naming a file
/// behaves exactly as before.
///
/// An entry's `mode` applies to every file it contributes; without one each
/// file keeps its own mode via [modeOf], so an executable stays executable.
///
/// **Explicit file entries win over a directory entry covering the same
/// destination**, so one file inside a swept tree can still be given its own
/// mode:
///
/// ```yaml
/// files:
///   ../runnable/data: { to: /usr/share/app/data, mode: '0644' }
///   ../runnable/data/secret.key: { to: /usr/share/app/data/secret.key, mode: '0600' }
/// ```
///
/// Symlinks to files are included (staging copies through them). A symlink to
/// a directory is skipped with a warning rather than descended into — it would
/// otherwise be ambiguous whether the package wants the link or the tree, and
/// refusing to descend also means a link cycle can never hang the walk.
PackageFiles expandPackageFiles(
  List<PackageFileEntry> entries, {
  required String Function(File) modeOf,
}) {
  final files = <String, String>{};
  final modes = <String, String>{};
  final warnings = <String>[];

  // Directory sweeps first, then explicit entries on top, so an explicit entry
  // wins whether it collides by source path or only by destination.
  final swept = <String, String>{};
  final sweptModes = <String, String>{};
  final explicit = <String, String>{};
  final explicitModes = <String, String>{};

  for (final e in entries) {
    if (FileSystemEntity.isDirectorySync(e.src)) {
      for (final f in _filesUnder(e.src, warnings)) {
        final rel = p.split(p.relative(f.path, from: e.src)).join('/');
        swept[f.path] = p.posix.join(e.dest, rel);
        sweptModes[f.path] = e.mode ?? modeOf(f);
      }
      continue;
    }
    explicit[e.src] = e.dest;
    final f = File(e.src);
    final mode = e.mode ?? (f.existsSync() ? modeOf(f) : null);
    if (mode != null) explicitModes[e.src] = mode;
  }

  final claimed = explicit.values.toSet();
  for (final e in swept.entries) {
    if (claimed.contains(e.value)) continue; // an explicit entry owns this dest
    files[e.key] = e.value;
    final mode = sweptModes[e.key];
    if (mode != null) modes[e.key] = mode;
  }
  files.addAll(explicit);
  modes.addAll(explicitModes);
  return (files: files, modes: modes, warnings: warnings);
}

/// Every file beneath [root], one level of symlink indirection resolved.
///
/// Listing with `followLinks: false` and resolving each entry's own type keeps
/// a symlinked file (which `whereType<File>()` would silently drop) while
/// never descending a symlinked directory.
List<File> _filesUnder(String root, List<String> warnings) {
  final out = <File>[];
  final pending = <String>[root];
  while (pending.isNotEmpty) {
    final dir = Directory(pending.removeLast());
    final List<FileSystemEntity> entries;
    try {
      entries = dir.listSync(followLinks: false);
    } on FileSystemException catch (e) {
      warnings.add('cannot read ${dir.path}: ${e.message}');
      continue;
    }
    for (final entity in entries) {
      final isLink = entity is Link;
      // typeSync follows links, so a symlinked file resolves to `file`.
      final type = FileSystemEntity.typeSync(entity.path);
      if (type == FileSystemEntityType.directory) {
        if (isLink) {
          warnings.add(
            'skipping symlinked directory ${entity.path} — name the real '
            'directory, or the individual files, to include it',
          );
          continue;
        }
        pending.add(entity.path);
      } else if (type == FileSystemEntityType.file) {
        out.add(File(entity.path));
      } else {
        warnings.add('skipping ${entity.path} (not a regular file)');
      }
    }
  }
  return out;
}
