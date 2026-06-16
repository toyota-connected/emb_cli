import 'dart:convert';
import 'dart:io';

import 'package:emb_cli/src/cross/process_runner.dart';
import 'package:path/path.dart' as p;

/// The sector extent of a 1-based partition within a disk image, parsed from
/// `sfdisk -J <image>` output.
class PartitionExtent {
  const PartitionExtent({
    required this.startSector,
    required this.sizeSectors,
    required this.sectorSize,
  });

  final int startSector;
  final int sizeSectors;
  final int sectorSize;
}

/// Parse `sfdisk -J` JSON and return the extent of the 1-based [partition], or
/// null when absent / malformed. Used to carve the rootfs partition out of a
/// `.img` with `dd` (no loop device, no root).
PartitionExtent? ext4PartitionExtent(String sfdiskJson, int partition) {
  final Object? doc;
  try {
    doc = jsonDecode(sfdiskJson);
  } on FormatException {
    return null;
  }
  if (doc is! Map) return null;
  final table = doc['partitiontable'];
  if (table is! Map) return null;
  final sectorSize = (table['sectorsize'] as num?)?.toInt() ?? 512;
  final parts = table['partitions'];
  if (parts is! List || partition < 1 || partition > parts.length) return null;
  final part = parts[partition - 1];
  if (part is! Map) return null;
  final start = (part['start'] as num?)?.toInt();
  final size = (part['size'] as num?)?.toInt();
  if (start == null || size == null) return null;
  return PartitionExtent(
    startSector: start,
    sizeSectors: size,
    sectorSize: sectorSize,
  );
}

/// Extract an ext-family filesystem image [fsImage] into [dest] using
/// `debugfs rdump` — read-only, no loop-mount, **no root**. Returns true when
/// the dump populated [dest].
///
/// This is the root-free alternative to `sudo losetup`+`mount`+`rsync` for
/// pulling a Debian image's rootfs into a cross sysroot.
Future<bool> extractExt4Tree(
  File fsImage,
  Directory dest, {
  ProcessRunner run = defaultProcessRunner,
}) async {
  dest.createSync(recursive: true);
  // `rdump <src-in-fs> <dest-on-host>` dumps a tree out of the image.
  final r = await run('debugfs', ['-R', 'rdump / ${dest.path}', fsImage.path]);
  // debugfs exits 0 even on a partial dump, so confirm dest was populated.
  return r.exitCode == 0 && dest.listSync().isNotEmpty;
}

/// Restore Debian's usr-merge symlinks (`lib`, `lib64`, `sbin`, `bin` →
/// `usr/<d>`) in [sysroot]. `debugfs rdump` can turn these into partial real
/// dirs, so the real libs end up only under `usr/lib/<multiarch>` and a
/// `libc.so` linker script's `/lib/...` references fail to resolve. For each
/// merged dir, move any stray entries into `usr/<d>` (without clobbering) and
/// replace it with a relative symlink.
void normalizeUsrMerge(Directory sysroot) {
  for (final d in const ['lib', 'lib64', 'libx32', 'sbin', 'bin']) {
    final entry = p.join(sysroot.path, d);
    final usr = Directory(p.join(sysroot.path, 'usr', d));
    if (!usr.existsSync()) continue;
    if (FileSystemEntity.isLinkSync(entry)) continue; // already a symlink
    final dir = Directory(entry);
    if (dir.existsSync()) {
      for (final e in dir.listSync(followLinks: false)) {
        final dest = p.join(usr.path, p.basename(e.path));
        if (FileSystemEntity.typeSync(dest, followLinks: false) ==
            FileSystemEntityType.notFound) {
          e.renameSync(dest); // move stray content into usr/<d>
        }
      }
      dir.deleteSync(recursive: true);
    }
    Link(entry).createSync('usr/$d');
  }
}

/// Extract a Debian `.deb` package's payload into [dest] with `dpkg-deb -x` —
/// no apt, no `chroot`, **no root**. This is how `-dev` packages are layered
/// into a cross sysroot without the qemu apt-chroot.
Future<bool> extractDeb(
  File deb,
  Directory dest, {
  ProcessRunner run = defaultProcessRunner,
}) async {
  dest.createSync(recursive: true);
  final r = await run('dpkg-deb', ['-x', deb.path, dest.path]);
  return r.exitCode == 0;
}
