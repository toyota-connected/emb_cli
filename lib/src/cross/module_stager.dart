import 'dart:io';

import 'package:path/path.dart' as p;

/// Locate the shared library [soname] (and its version/symlink chain) under
/// [buildDir] and stage it into [libDir], collapsing every symlink name onto
/// the real file so both the bare soname and any embedded SONAME (`libX.so.1`)
/// resolve at load time.
///
/// A build tree typically holds `libfoo.so.1.2.3` (the real file) with
/// `libfoo.so.1` and `libfoo.so` symlinks beside it. This copies the real file
/// into [libDir] under its own basename and recreates every matched name — plus
/// the declared [soname] itself — as a sibling symlink onto that real file, so
/// `DynamicLibrary.open('<soname>')` and any `DT_NEEDED` SONAME both resolve.
///
/// Returns the staged real [File] (inside [libDir]), or null when no matching
/// real file is found under [buildDir]. CMake's internal scratch dirs
/// (`CMakeFiles/**`) are ignored.
File? stageSharedLibrary({
  required String soname,
  required Directory buildDir,
  required Directory libDir,
}) {
  // Entries whose basename is the soname or a versioned form (`libX.so.1.2`),
  // excluding CMake's internal scratch dirs.
  final matches = <FileSystemEntity>[];
  for (final e in buildDir.listSync(recursive: true, followLinks: false)) {
    final base = p.basename(e.path);
    if (base != soname && !base.startsWith('$soname.')) continue;
    if (p
        .split(p.relative(e.path, from: buildDir.path))
        .contains('CMakeFiles')) {
      continue;
    }
    matches.add(e);
  }
  if (matches.isEmpty) return null;

  // The real regular file the chain resolves to: a matched non-link file, else
  // follow a matched symlink to its target.
  File? real;
  for (final e in matches) {
    if (FileSystemEntity.isLinkSync(e.path)) continue;
    if (FileSystemEntity.isFileSync(e.path)) {
      real = File(e.path);
      break;
    }
  }
  if (real == null) {
    for (final e in matches) {
      try {
        final t = File(e.path).resolveSymbolicLinksSync();
        if (FileSystemEntity.isFileSync(t)) {
          real = File(t);
          break;
        }
      } on FileSystemException {
        // Dangling link — keep looking.
      }
    }
  }
  if (real == null) return null;

  libDir.createSync(recursive: true);
  final realBase = p.basename(real.path);
  final staged = File(p.join(libDir.path, realBase));
  real.copySync(staged.path);

  // Reproduce every name (the declared soname + each matched link name) as a
  // sibling symlink onto the real file, so the loader resolves any of them.
  final names = {soname, for (final e in matches) p.basename(e.path)};
  for (final n in names) {
    if (n == realBase) continue;
    final dest = p.join(libDir.path, n);
    if (FileSystemEntity.typeSync(dest, followLinks: false) !=
        FileSystemEntityType.notFound) {
      FileSystemEntity.isLinkSync(dest)
          ? Link(dest).deleteSync()
          : File(dest).deleteSync();
    }
    Link(dest).createSync(realBase);
  }
  return staged;
}
