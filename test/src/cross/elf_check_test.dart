import 'dart:io';
import 'dart:typed_data';

import 'package:emb_cli/src/cross/elf_check.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Build a minimal 64-byte little-endian ELF header with the given class,
/// machine, and flags. Enough for the header reader; the body is irrelevant.
Uint8List _elf({
  int eiClass = 2,
  int eiData = 1,
  int eMachine = 0xB7,
  int eFlags = 0,
}) {
  final b = Uint8List(64);
  b[0] = 0x7f;
  b[1] = 0x45; // E
  b[2] = 0x4c; // L
  b[3] = 0x46; // F
  b[4] = eiClass;
  b[5] = eiData;
  ByteData.sublistView(b)
    ..setUint16(18, eMachine, Endian.little)
    ..setUint32(eiClass == 1 ? 36 : 48, eFlags, Endian.little);
  return b;
}

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('emb_elf_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  File write(String name, List<int> bytes) =>
      File(p.join(tmp.path, name))..writeAsBytesSync(bytes);

  group('readElfHeader', () {
    test('parses class, data, machine and flags', () {
      final f = write('a.so', _elf(eFlags: 0x400));
      final h = readElfHeader(f)!;
      expect(h.eiClass, 2);
      expect(h.eiData, 1);
      expect(h.eMachine, 0xB7);
      expect(h.eFlags, 0x400);
    });

    test('reads e_flags from offset 36 for 32-bit objects', () {
      final f = write(
        'arm.so',
        _elf(eiClass: 1, eMachine: 0x28, eFlags: 0x400),
      );
      expect(readElfHeader(f)!.eFlags, 0x400);
    });

    test('returns null for a non-ELF file', () {
      expect(readElfHeader(write('t.txt', 'not an elf'.codeUnits)), isNull);
    });

    test('returns null for a file shorter than the header', () {
      expect(readElfHeader(write('short', [0x7f, 0x45, 0x4c, 0x46])), isNull);
    });
  });

  group('verifyElfForTriple', () {
    test('accepts a matching aarch64 object', () {
      final f = write('ok.so', _elf());
      expect(verifyElfForTriple(f, 'aarch64-none-linux-gnu'), isNull);
    });

    test('rejects a host-arch (x86_64) object for an aarch64 target', () {
      final f = write('host.so', _elf(eMachine: 0x3E));
      final err = verifyElfForTriple(f, 'aarch64-none-linux-gnu');
      expect(err, contains('e_machine'));
    });

    test('rejects a 64-bit object for a 32-bit arm target', () {
      // Right machine family cannot happen with wrong class here, so use a
      // class mismatch with a machine emb does not pin.
      final f = write('w.so', _elf(eMachine: 0x28));
      final err = verifyElfForTriple(f, 'arm-none-linux-gnueabihf');
      // Machine matches (0x28); the class check catches the 64-bit build.
      expect(err, contains('64-bit'));
    });

    test('rejects a soft-float object for a hard-float arm target', () {
      final f = write('soft.so', _elf(eiClass: 1, eMachine: 0x28));
      final err = verifyElfForTriple(f, 'arm-none-linux-gnueabihf');
      expect(err, contains('soft-float'));
    });

    test('accepts a hard-float arm object for a hard-float target', () {
      final f = write(
        'hard.so',
        _elf(eiClass: 1, eMachine: 0x28, eFlags: 0x400),
      );
      expect(verifyElfForTriple(f, 'arm-none-linux-gnueabihf'), isNull);
    });

    test('skips a non-ELF file (linker script / symlink target concern)', () {
      final f = write('s.so', 'INPUT(x)'.codeUnits);
      expect(verifyElfForTriple(f, 'aarch64-none-linux-gnu'), isNull);
    });
  });

  group('parseNeededSonames', () {
    test('pulls DT_NEEDED sonames in file order', () {
      const out = '''
Dynamic section at offset 0x2d88 contains 27 entries:
  Tag        Type                         Name/Value
 0x0000000000000001 (NEEDED)             Shared library: [libihs_shared.so.1]
 0x0000000000000001 (NEEDED)             Shared library: [libEGL.so.1]
 0x0000000000000001 (NEEDED)             Shared library: [libc.so.6]
 0x000000000000000e (SONAME)             Library soname: [homescreen]
''';
      expect(parseNeededSonames(out), [
        'libihs_shared.so.1',
        'libEGL.so.1',
        'libc.so.6',
      ]);
    });

    test('returns empty for output with no NEEDED entries', () {
      expect(parseNeededSonames('no dynamic section here'), isEmpty);
    });
  });

  group('parseVersionNeeds / parseVersionDefs', () {
    // Trimmed from real `readelf -V` output. The .gnu.version table is kept
    // because it also carries parenthesised version names, and an earlier
    // version of the parser read those as requirements.
    const needsOutput = '''
Version symbols section '.gnu.version' contains 129 entries:
 Addr: 0x000000000001a2a8  Offset: 0x0001a2a8  Link: 9 (.dynsym)
  000:   0 (*local*)       2 (GLIBC_2.3)     3 (GLIBC_2.2.5)   0 (*local*)
  04c:   c (GLIBC_2.38)    3 (GLIBC_2.2.5)   3 (GLIBC_2.2.5)   3 (GLIBC_2.2.5)

Version needs section '.gnu.version_r' contains 2 entries:
 Addr: 0x000000000001a3b0  Offset: 0x0001a3b0  Link: 10 (.dynstr)
  000000: Version: 1  File: libselinux.so.1  Cnt: 1
  0x0010:   Name: LIBSELINUX_1.0  Flags: none  Version: 8
  0x0020: Version: 1  File: libc.so.6  Cnt: 3
  0x0030:   Name: GLIBC_ABI_DT_RELR  Flags: none  Version: 14
  0x0040:   Name: GLIBC_2.28  Flags: none  Version: 13
  0x0050:   Name: GLIBC_2.38  Flags: none  Version: 12
''';

    const defsOutput = '''
Version definition section '.gnu.version_d' contains 46 entries:
 Addr: 0x0000000000198060  Offset: 0x00198060  Link: 8 (.dynstr)
  000000: Rev: 1  Flags: BASE  Index: 1  Cnt: 1  Name: libc.so.6
  0x001c: Rev: 1  Flags: none  Index: 2  Cnt: 1  Name: GLIBC_2.2.5
  0x0038: Rev: 1  Flags: none  Index: 3  Cnt: 2  Name: GLIBC_2.2.6
  0x0054: Parent 1: GLIBC_2.2.5
''';

    test('groups required versions under the library that defines them', () {
      expect(parseVersionNeeds(needsOutput), {
        'libselinux.so.1': {'LIBSELINUX_1.0'},
        'libc.so.6': {'GLIBC_ABI_DT_RELR', 'GLIBC_2.28', 'GLIBC_2.38'},
      });
    });

    test('ignores the per-symbol version table', () {
      // Those lines name versions too, in parentheses, and belong to no File:.
      final needs = parseVersionNeeds(needsOutput);
      expect(needs.values.expand((v) => v), isNot(contains('GLIBC_2.2.5')));
    });

    test('an object with no version sections needs nothing', () {
      expect(parseVersionNeeds('Dynamic section at offset 0x1\n'), isEmpty);
    });

    test('reads definitions, skipping BASE and Parent lines', () {
      expect(parseVersionDefs(defsOutput), {'GLIBC_2.2.5', 'GLIBC_2.2.6'});
    });

    test('definitions do not leak in from a needs section', () {
      // Both sections appear in one readelf run for a library; a `Name:` after
      // the needs heading is a requirement, not a definition.
      expect(parseVersionDefs(needsOutput), isEmpty);
    });

    test('needs do not leak in from a definitions section', () {
      expect(parseVersionNeeds(defsOutput), isEmpty);
    });
  });
}
