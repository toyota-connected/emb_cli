import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

/// The result of looking for the embedder binary in a build tree.
class EmbedderSearch {
  const EmbedderSearch.found(File this.file) : candidates = const [];

  const EmbedderSearch.none() : file = null, candidates = const [];

  /// More than one executable, and nothing to choose between them by.
  const EmbedderSearch.ambiguous(this.candidates) : file = null;

  /// The binary, or null when there is none or no way to pick one.
  final File? file;

  /// The executables found, relative to the build directory and sorted, when
  /// there was more than one. Empty otherwise.
  final List<String> candidates;

  bool get isAmbiguous => candidates.isNotEmpty;
}

/// The embedder binary of a build: [bin] resolved under [buildDir] when the
/// manifest names it (`cross.package.bin`), else the one executable in the
/// tree.
///
/// Unnamed, the binary has to be found, and a wrong find ships: it is packaged
/// and launched. So the search is strict on two counts.
///
/// It takes executables only. A shared library carries the ELF magic and an
/// execute bit like a program does (linkers write `.so` files mode 0755), and
/// `e_type` does not separate them, since a PIE executable and a shared
/// object are both `ET_DYN`. See [isElfExecutable].
///
/// And it does not guess. With two executables in the tree there is no
/// telling which is the embedder, and the order a directory lists them in is
/// the filesystem's: the same manifest picked `homescreen` on tmpfs and
/// `libihs_shared.so.1` on ext4. More than one is [EmbedderSearch.ambiguous],
/// with the candidates, for the caller to ask for `cross.package.bin`.
EmbedderSearch findEmbedderBinary(String buildDir, String? bin) {
  if (bin != null) {
    final f = File(p.join(buildDir, bin));
    return f.existsSync()
        ? EmbedderSearch.found(f)
        : const EmbedderSearch.none();
  }
  final dir = Directory(buildDir);
  if (!dir.existsSync()) return const EmbedderSearch.none();
  final found = <File>[];
  // Links are not followed: `homescreen -> homescreen-3.0` is one program,
  // and following it would count two.
  for (final e in dir.listSync(recursive: true, followLinks: false)) {
    if (e is! File) continue;
    // CMake's compiler-probe binaries (CMakeFiles/**) are executables too.
    if (p.split(p.relative(e.path, from: buildDir)).contains('CMakeFiles')) {
      continue;
    }
    if (looksLikeSharedLibraryName(p.basename(e.path))) continue;
    if (e.statSync().mode & 0x49 == 0) continue;
    if (isElfExecutable(e)) found.add(e);
  }
  if (found.isEmpty) return const EmbedderSearch.none();
  if (found.length == 1) return EmbedderSearch.found(found.single);
  return EmbedderSearch.ambiguous(
    [for (final f in found) p.relative(f.path, from: buildDir)]..sort(),
  );
}

/// What to tell the user when [findEmbedderBinary] returned no file for
/// [buildDir]: the name that is not there, the candidates it would not choose
/// between, or that there is nothing to find.
String describeMissingEmbedder({
  required String buildDir,
  String? backend,
  String? bin,
}) {
  final tag = backend ?? '';
  if (bin != null) {
    return '  $tag: cross.package.bin "$bin" is not in $buildDir';
  }
  final search = findEmbedderBinary(buildDir, null);
  if (!search.isAmbiguous) {
    return '  $tag: no embedder binary in $buildDir (set cross.package.bin)';
  }
  final count = search.candidates.length;
  final head =
      '  $tag: $count executables in $buildDir, and nothing says which is '
      'the embedder:';
  return [
    head,
    for (final c in search.candidates) '      $c',
    '    Set cross.package.bin to one of them.',
  ].join('\n');
}

/// `libfoo.so`, `libfoo.so.1`, `libfoo.so.1.2.3`.
bool looksLikeSharedLibraryName(String name) =>
    RegExp(r'\.so(\.[0-9]+)*$').hasMatch(name);

const _etExec = 2;
const _etDyn = 3;
const _ptDynamic = 2;
const _ptInterp = 3;
const _dtFlags1 = 0x6ffffffb;
const _df1Pie = 0x08000000;

/// Whether [file] is an ELF program, as opposed to a shared library, an
/// object file or not ELF at all.
///
/// `ET_EXEC` is a program. `ET_DYN` is a program when it asks for an
/// interpreter (a `PT_INTERP` program header), as a PIE executable does and
/// an ordinary shared library does not, or when the linker marked it
/// `DF_1_PIE` in its dynamic section, which is how a static PIE (no
/// interpreter; common for musl targets) says what it is.
///
/// A few libraries do carry `PT_INTERP` (glibc's `libc.so.6` runs as a
/// program), which is why callers also filter on the name.
bool isElfExecutable(File file) {
  final RandomAccessFile raf;
  try {
    raf = file.openSync();
  } on FileSystemException {
    return false;
  }
  try {
    final head = raf.readSync(64);
    if (head.length < 52 ||
        head[0] != 0x7f ||
        head[1] != 0x45 ||
        head[2] != 0x4c ||
        head[3] != 0x46) {
      return false;
    }
    final is64 = head[4] == 2;
    if (is64 && head.length < 64) return false;
    final endian = head[5] == 2 ? Endian.big : Endian.little;
    final view = ByteData.sublistView(Uint8List.fromList(head));
    final type = view.getUint16(16, endian);
    if (type == _etExec) return true;
    if (type != _etDyn) return false;

    final phoff = is64
        ? view.getUint64(32, endian)
        : view.getUint32(28, endian);
    final phentsize = view.getUint16(is64 ? 54 : 42, endian);
    final phnum = view.getUint16(is64 ? 56 : 44, endian);
    if (phoff == 0 || phentsize < 4 || phnum == 0) return false;
    raf.setPositionSync(phoff);
    final table = raf.readSync(phentsize * phnum);
    final entries = ByteData.sublistView(Uint8List.fromList(table));
    int? dynOffset;
    var dynSize = 0;
    for (var i = 0; (i + 1) * phentsize <= table.length; i++) {
      final at = i * phentsize;
      // p_type is the first word of an entry in both classes.
      final type = entries.getUint32(at, endian);
      if (type == _ptInterp) return true;
      if (type == _ptDynamic && phentsize >= (is64 ? 40 : 20)) {
        dynOffset = is64
            ? entries.getUint64(at + 8, endian)
            : entries.getUint32(at + 4, endian);
        dynSize = is64
            ? entries.getUint64(at + 32, endian)
            : entries.getUint32(at + 16, endian);
      }
    }
    // No interpreter. A static PIE still says so in DT_FLAGS_1.
    if (dynOffset == null || dynSize <= 0 || dynSize > 1 << 20) return false;
    raf.setPositionSync(dynOffset);
    final dyn = raf.readSync(dynSize);
    final tags = ByteData.sublistView(Uint8List.fromList(dyn));
    final step = is64 ? 16 : 8;
    for (var at = 0; at + step <= dyn.length; at += step) {
      final tag = is64
          ? tags.getUint64(at, endian)
          : tags.getUint32(at, endian);
      if (tag == 0) break;
      if (tag != _dtFlags1) continue;
      final value = is64
          ? tags.getUint64(at + 8, endian)
          : tags.getUint32(at + 4, endian);
      return value & _df1Pie != 0;
    }
    return false;
  } on FileSystemException {
    return false;
  } finally {
    raf.closeSync();
  }
}
