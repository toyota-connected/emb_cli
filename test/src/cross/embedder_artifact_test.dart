import 'dart:io';
import 'dart:typed_data';

import 'package:emb_cli/src/cross/embedder_artifact.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

const _etRel = 1;
const _etExec = 2;
const _etDyn = 3;
const _ptLoad = 1;
const _ptDynamic = 2;
const _ptInterp = 3;
const _dtFlags1 = 0x6ffffffb;
const _df1Pie = 0x08000000;

/// A minimal ELF: a file header, then one program header per entry of
/// [segments]. Enough for the reader; there is no body.
///
/// With [flags1] a `PT_DYNAMIC` segment is added whose section holds one
/// `DT_FLAGS_1` entry of that value, after a `DT_NEEDED` to step over.
Uint8List elf({
  int type = _etDyn,
  List<int> segments = const [_ptLoad, _ptInterp],
  int? flags1,
  bool is64 = true,
  Endian endian = Endian.little,
}) {
  final all = [...segments, if (flags1 != null) _ptDynamic];
  final ehsize = is64 ? 64 : 52;
  final phentsize = is64 ? 56 : 32;
  final dynEntry = is64 ? 16 : 8;
  final dynOffset = ehsize + phentsize * all.length;
  final dynSize = flags1 == null ? 0 : dynEntry * 3;
  final b = Uint8List(dynOffset + dynSize)
    ..setAll(0, [
      ...[0x7f, 0x45, 0x4c, 0x46],
      if (is64) 2 else 1,
      if (endian == Endian.big) 2 else 1,
    ]);
  final v = ByteData.sublistView(b)..setUint16(16, type, endian);
  void word(int at, int value) =>
      is64 ? v.setUint64(at, value, endian) : v.setUint32(at, value, endian);
  if (is64) {
    v
      ..setUint64(32, all.isEmpty ? 0 : ehsize, endian)
      ..setUint16(54, phentsize, endian)
      ..setUint16(56, all.length, endian);
  } else {
    v
      ..setUint32(28, all.isEmpty ? 0 : ehsize, endian)
      ..setUint16(42, phentsize, endian)
      ..setUint16(44, all.length, endian);
  }
  for (var i = 0; i < all.length; i++) {
    final at = ehsize + i * phentsize;
    v.setUint32(at, all[i], endian);
    if (all[i] == _ptDynamic) {
      // p_offset and p_filesz.
      word(at + (is64 ? 8 : 4), dynOffset);
      word(at + (is64 ? 32 : 16), dynSize);
    }
  }
  if (flags1 != null) {
    word(dynOffset, 1); // DT_NEEDED
    word(dynOffset + dynEntry, _dtFlags1);
    word(dynOffset + dynEntry + dynEntry ~/ 2, flags1);
    // The third entry stays zero: DT_NULL.
  }
  return b;
}

/// A shared library: `ET_DYN` with nothing asking for an interpreter.
Uint8List sharedLibrary() => elf(segments: const [_ptLoad]);

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('emb_artifact_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  File write(String rel, List<int> bytes, {bool executable = true}) {
    final f = File(p.join(tmp.path, rel))
      ..createSync(recursive: true)
      ..writeAsBytesSync(bytes);
    if (executable) Process.runSync('chmod', ['+x', f.path]);
    return f;
  }

  group('isElfExecutable', () {
    test('a PIE executable: ET_DYN that asks for an interpreter', () {
      expect(isElfExecutable(write('a', elf())), isTrue);
    });

    test('a non-PIE executable: ET_EXEC', () {
      expect(
        isElfExecutable(write('a', elf(type: _etExec, segments: const []))),
        isTrue,
      );
    });

    // No interpreter to ask for, so the linker's DF_1_PIE mark is all that
    // tells it from a library. Usual for a musl target.
    test('a static PIE: ET_DYN marked DF_1_PIE', () {
      for (final is64 in [true, false]) {
        for (final endian in [Endian.little, Endian.big]) {
          expect(
            isElfExecutable(
              write(
                'a',
                elf(
                  segments: const [_ptLoad],
                  flags1: _df1Pie | 1,
                  is64: is64,
                  endian: endian,
                ),
              ),
            ),
            isTrue,
            reason: 'is64=$is64 $endian',
          );
        }
      }
    });

    // DF_1_NOW and friends: a library with flags, none of them PIE.
    test('a shared library with other DT_FLAGS_1 bits is not one', () {
      expect(
        isElfExecutable(write('a', elf(segments: const [_ptLoad], flags1: 1))),
        isFalse,
      );
    });

    // The case the old "ELF magic and an execute bit" test let through.
    test('a shared library is not one', () {
      expect(isElfExecutable(write('a', sharedLibrary())), isFalse);
    });

    test('an object file is not one', () {
      expect(
        isElfExecutable(write('a', elf(type: _etRel, segments: const []))),
        isFalse,
      );
    });

    test('32-bit and big-endian headers are read where they are', () {
      for (final endian in [Endian.little, Endian.big]) {
        for (final is64 in [true, false]) {
          expect(
            isElfExecutable(write('p', elf(is64: is64, endian: endian))),
            isTrue,
            reason: 'pie is64=$is64 $endian',
          );
          expect(
            isElfExecutable(
              write(
                'l',
                elf(is64: is64, endian: endian, segments: const [_ptLoad]),
              ),
            ),
            isFalse,
            reason: 'lib is64=$is64 $endian',
          );
        }
      }
    });

    test('the interpreter need not be the first or second segment', () {
      expect(
        isElfExecutable(
          write('a', elf(segments: const [6, _ptLoad, _ptLoad, _ptInterp])),
        ),
        isTrue,
      );
    });

    test('not ELF, truncated, or missing is not one', () {
      expect(isElfExecutable(write('t', '#!/bin/sh\n'.codeUnits)), isFalse);
      expect(isElfExecutable(write('s', [0x7f, 0x45, 0x4c, 0x46])), isFalse);
      // A program-header table the file is too short to hold.
      expect(isElfExecutable(write('c', elf().sublist(0, 70))), isFalse);
      expect(isElfExecutable(File(p.join(tmp.path, 'absent'))), isFalse);
    });
  });

  test('looksLikeSharedLibraryName', () {
    for (final name in ['libfoo.so', 'libfoo.so.1', 'libihs_shared.so.1.0.0']) {
      expect(looksLikeSharedLibraryName(name), isTrue, reason: name);
    }
    for (final name in ['homescreen', 'so', 'tool.sock', 'a.so.txt', 'x.sox']) {
      expect(looksLikeSharedLibraryName(name), isFalse, reason: name);
    }
  });

  group('findEmbedderBinary', () {
    test('package.bin is taken as given, whatever else is there', () {
      write('shell/homescreen', elf());
      write('tools/other', elf());
      final found = findEmbedderBinary(tmp.path, 'shell/homescreen');
      expect(found.file!.path, p.join(tmp.path, 'shell/homescreen'));
      expect(found.isAmbiguous, isFalse);
    });

    test('package.bin that is not there finds nothing, and does not guess', () {
      write('shell/homescreen', elf());
      final found = findEmbedderBinary(tmp.path, 'bin/homescreen');
      expect(found.file, isNull);
      expect(found.isAmbiguous, isFalse);
    });

    // ivi-homescreen's tree, the one in the issue: the old search returned
    // whichever the directory listed first, and on ext4 that was the library.
    test('one executable beside its shared library is the executable', () {
      write('shell/homescreen', elf());
      write('shell/lib/libihs_shared.so.1.0.0', sharedLibrary());
      // Name alone is not trusted either way.
      write('shell/lib/ihs_plugin', sharedLibrary());
      expect(
        findEmbedderBinary(tmp.path, null).file!.path,
        p.join(tmp.path, 'shell/homescreen'),
      );
    });

    // glibc's libc.so.6 asks for an interpreter and runs as a program.
    test('a library that is also a program is still a library', () {
      write('homescreen', elf());
      write('lib/libc.so.6', elf());
      expect(
        findEmbedderBinary(tmp.path, null).file!.path,
        p.join(tmp.path, 'homescreen'),
      );
    });

    test('two executables: none is chosen, both are named, sorted', () {
      write('tools/zeta', elf());
      write('shell/homescreen', elf());
      final found = findEmbedderBinary(tmp.path, null);
      expect(found.file, isNull);
      expect(found.isAmbiguous, isTrue);
      expect(found.candidates, ['shell/homescreen', 'tools/zeta']);
    });

    test("CMake's compiler probes are not candidates", () {
      write('CMakeFiles/4.0.0/CompilerIdC/a.out', elf());
      write('sub/CMakeFiles/probe', elf());
      write('homescreen', elf());
      expect(findEmbedderBinary(tmp.path, null).file, isNotNull);
    });

    // Only the tree below the build directory is examined for that name.
    test('a build directory under a CMakeFiles path still works', () {
      final dir = Directory(p.join(tmp.path, 'CMakeFiles', 'build'))
        ..createSync(recursive: true);
      write('CMakeFiles/build/homescreen', elf());
      expect(findEmbedderBinary(dir.path, null).file, isNotNull);
    });

    test('an executable without its execute bit is not a candidate', () {
      write('homescreen', elf(), executable: false);
      expect(findEmbedderBinary(tmp.path, null).file, isNull);
    });

    test('a link to the executable does not make two of them', () {
      final real = write('homescreen-3.0', elf());
      Link(p.join(tmp.path, 'homescreen')).createSync(real.path);
      final found = findEmbedderBinary(tmp.path, null);
      expect(found.isAmbiguous, isFalse);
      expect(found.file!.path, real.path);
    });

    group('describeMissingEmbedder', () {
      test('names every candidate, and what to set', () {
        write('tools/zeta', elf());
        write('shell/homescreen', elf());
        final text = describeMissingEmbedder(
          buildDir: tmp.path,
          backend: 'wayland-egl',
        );
        expect(text, contains('wayland-egl: 2 executables'));
        expect(text, contains('      shell/homescreen\n      tools/zeta'));
        expect(text, contains('Set cross.package.bin to one of them.'));
      });

      test('a package.bin that is not there is named', () {
        write('shell/homescreen', elf());
        expect(
          describeMissingEmbedder(buildDir: tmp.path, bin: 'bin/hs'),
          contains('cross.package.bin "bin/hs" is not in'),
        );
      });

      // Only libraries: there is no embedder to name.
      test('nothing executable says to set package.bin', () {
        write('lib/libihs_shared.so.1', sharedLibrary());
        expect(
          describeMissingEmbedder(buildDir: tmp.path),
          contains('no embedder binary'),
        );
      });
    });

    test('nothing there, or no directory, finds nothing', () {
      expect(findEmbedderBinary(tmp.path, null).file, isNull);
      expect(findEmbedderBinary(p.join(tmp.path, 'absent'), null).file, isNull);
    });
  }, testOn: '!windows');
}
