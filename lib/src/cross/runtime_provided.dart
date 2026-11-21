import 'dart:io';

import 'package:path/path.dart' as p;

/// The `lib<name>.so` of each `-l` [names] that the SDK links as a shared
/// object but the runtime does not ship, sorted.
///
/// [sdkLibDirs] are where the linker finds `lib<name>.so` in the SDK;
/// [runtimeFiles] are the file names in the runtime's library dirs.
///
/// An `-l` name need not match what the runtime ships: `-lSDL2` links
/// `libSDL2.so`, a development link to `libSDL2-2.0.so.0`, and NSS ships an
/// unversioned `libnss3.so`. So the SDK's link is followed hop by hop, and the
/// runtime provides the library when it has any name along the way. A
/// `lib<name>.so` that is a linker script (`libm.so`, `libc.so`) is provided
/// when the runtime has every shared object the script names.
///
/// A name the SDK has only as a static archive is linked in, so it is never
/// missing; nor is one found in no dir, since nothing says it is shared.
List<String> libsMissingFromRuntime(
  Iterable<String> names,
  List<String> sdkLibDirs,
  Set<String> runtimeFiles,
) {
  final missing = <String>[];
  for (final name in names.toSet().toList()..sort()) {
    final so = sdkLibDirs
        .map((d) => p.join(d, 'lib$name.so'))
        .where(
          // The link itself: an absolute target names a path in the SDK's
          // root, which need not exist on the host.
          (f) =>
              FileSystemEntity.typeSync(f, followLinks: false) !=
              FileSystemEntityType.notFound,
        )
        .firstOrNull;
    if (so == null) continue; // static-only, or not the SDK's to answer for
    if (!_provided(so, runtimeFiles)) missing.add('lib$name.so');
  }
  return missing;
}

bool _provided(String so, Set<String> runtimeFiles) {
  // Follow the link chain within its directory tree. An absolute target would
  // resolve against the host, not the SDK, so the walk stops there and judges
  // by the names seen so far.
  var cur = so;
  final seen = <String>[];
  for (var hop = 0; hop < 40; hop++) {
    if (!FileSystemEntity.isLinkSync(cur)) break;
    final target = Link(cur).targetSync();
    if (p.isAbsolute(target)) {
      seen.add(p.basename(target));
      return seen.any(runtimeFiles.contains);
    }
    cur = p.normalize(p.join(p.dirname(cur), target));
    seen.add(p.basename(cur));
  }
  if (seen.any(runtimeFiles.contains)) return true;

  final file = File(cur);
  if (!file.existsSync()) return false;
  if (_isElf(file)) return runtimeFiles.contains(p.basename(cur));

  // A linker script: every shared object it names must be in the runtime.
  final String text;
  try {
    text = file.readAsStringSync();
  } on Exception {
    return false;
  }
  final named = RegExp(
    r'[^\s()]+\.so(\.[0-9]+)*(?=[\s)]|$)',
  ).allMatches(text).map((m) => p.basename(m.group(0)!)).toSet();
  return named.isNotEmpty && named.every(runtimeFiles.contains);
}

bool _isElf(File f) {
  try {
    final raf = f.openSync();
    try {
      final b = raf.readSync(4);
      return b.length == 4 &&
          b[0] == 0x7f &&
          b[1] == 0x45 &&
          b[2] == 0x4c &&
          b[3] == 0x46;
    } finally {
      raf.closeSync();
    }
  } on FileSystemException {
    return false;
  }
}
