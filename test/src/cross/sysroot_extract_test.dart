import 'dart:io';

import 'package:emb_cli/src/cross/sysroot_extract.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('ext4PartitionExtent', () {
    const sfdisk = '''
{
  "partitiontable": {
    "label": "dos",
    "sectorsize": 512,
    "partitions": [
      { "node": "img1", "start": 8192,   "size": 524288,  "type": "c" },
      { "node": "img2", "start": 532480, "size": 7000000, "type": "83" }
    ]
  }
}''';

    test('returns the requested partition extent (rootfs = p2)', () {
      final e = ext4PartitionExtent(sfdisk, 2)!;
      expect(e.startSector, 532480);
      expect(e.sizeSectors, 7000000);
      expect(e.sectorSize, 512);
    });

    test('null for out-of-range or malformed input', () {
      expect(ext4PartitionExtent(sfdisk, 5), isNull);
      expect(ext4PartitionExtent('not json', 1), isNull);
      expect(ext4PartitionExtent('{}', 1), isNull);
    });
  });

  group('extractExt4Tree (real debugfs, no root)', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('emb_ext4_'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test('dumps an ext4 image into a sysroot dir', () async {
      // Populate a source tree, then build an ext4 image from it (rootless).
      final src = Directory(p.join(tmp.path, 'src'));
      File(p.join(src.path, 'etc', 'os-release'))
        ..createSync(recursive: true)
        ..writeAsStringSync('VERSION_CODENAME=bookworm\n');
      File(p.join(src.path, 'usr', 'lib', 'libfoo.so.1'))
        ..createSync(recursive: true)
        ..writeAsStringSync('x');

      final img = File(p.join(tmp.path, 'fs.img'));
      final mk = await Process.run('mke2fs', [
        '-q',
        '-F',
        '-t',
        'ext4',
        '-d',
        src.path,
        img.path,
        '16384', // 1K blocks -> 16 MB
      ]);
      // Skip gracefully if e2fsprogs tooling isn't usable in this environment.
      if (mk.exitCode != 0) {
        markTestSkipped('mke2fs unavailable: ${mk.stderr}');
        return;
      }

      final dest = Directory(p.join(tmp.path, 'sysroot'));
      final ok = await extractExt4Tree(img, dest);

      expect(ok, isTrue);
      expect(File(p.join(dest.path, 'etc', 'os-release')).existsSync(), isTrue);
      expect(
        File(p.join(dest.path, 'usr', 'lib', 'libfoo.so.1')).existsSync(),
        isTrue,
      );
    });
  });
}
