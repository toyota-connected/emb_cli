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
}
