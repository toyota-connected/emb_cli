import 'dart:io';
import 'dart:typed_data';

import 'package:emb_cli/src/cross/cross_arch.dart';

/// `EF_ARM_ABI_FLOAT_HARD` — set in an ARM ELF's `e_flags` when the object uses
/// the hard-float procedure-call ABI.
const int _efArmAbiFloatHard = 0x400;

/// The fields of an ELF file header emb needs to tell a target artifact apart
/// from a host-arch build: the class (32/64-bit), byte order, machine, and
/// (for ARM) the ABI flags.
class ElfHeader {
  const ElfHeader({
    required this.eiClass,
    required this.eiData,
    required this.eMachine,
    required this.eFlags,
  });

  /// `EI_CLASS`: 1 = 32-bit (ELFCLASS32), 2 = 64-bit (ELFCLASS64).
  final int eiClass;

  /// `EI_DATA`: 1 = little-endian (ELFDATA2LSB), 2 = big-endian.
  final int eiData;

  /// `e_machine`, e.g. 0xB7 (`EM_AARCH64`) or 0x28 (`EM_ARM`).
  final int eMachine;

  /// `e_flags` — arch-specific; used only to read the ARM float-ABI bit.
  final int eFlags;
}

/// Parse the ELF header of [file], or return null when it is not an ELF object
/// — too short, or missing the `\x7fELF` magic (a linker script, a text stub,
/// or `libfoo.so` that is really a GNU ld script all land here). Reading a
/// symlink follows it to its target.
ElfHeader? readElfHeader(File file) {
  final RandomAccessFile raf;
  try {
    raf = file.openSync();
  } on FileSystemException {
    return null;
  }
  try {
    final bytes = raf.readSync(64);
    if (bytes.length < 64) return null;
    if (bytes[0] != 0x7f ||
        bytes[1] != 0x45 || // 'E'
        bytes[2] != 0x4c || // 'L'
        bytes[3] != 0x46) {
      // 'F'
      return null;
    }
    final eiClass = bytes[4];
    final eiData = bytes[5];
    final little = eiData != 2; // treat anything but ELFDATA2MSB as LE
    final view = ByteData.sublistView(Uint8List.fromList(bytes));
    final endian = little ? Endian.little : Endian.big;
    final eMachine = view.getUint16(18, endian);
    // e_flags sits after the class-dependent e_entry/e_phoff/e_shoff run:
    // offset 36 for ELFCLASS32, 48 for ELFCLASS64.
    final eFlags = view.getUint32(eiClass == 1 ? 36 : 48, endian);
    return ElfHeader(
      eiClass: eiClass,
      eiData: eiData,
      eMachine: eMachine,
      eFlags: eFlags,
    );
  } finally {
    raf.closeSync();
  }
}

/// Check that [file] is an ELF object built for [triple]. Returns null when it
/// matches — or when it is not an ELF object at all, since symlinks and linker
/// scripts are the caller's concern, not an arch mismatch. Otherwise returns a
/// one-line reason naming the discrepancy (wrong machine, wrong word size, or a
/// soft-float object under a hard-float ABI).
///
/// This is the guard against a silent host-arch fallback: a module or hook that
/// discovers the host compiler and "succeeds" produces a valid ELF for the
/// wrong `e_machine`, which this catches at staging time.
String? verifyElfForTriple(File file, String triple) {
  final h = readElfHeader(file);
  if (h == null) return null;

  final wantMachine = elfMachine(triple);
  if (wantMachine != 0 && h.eMachine != wantMachine) {
    return 'built for e_machine 0x${h.eMachine.toRadixString(16)}, '
        'target $triple needs 0x${wantMachine.toRadixString(16)}';
  }

  final wantClass = elfClass(triple);
  if (h.eiClass != wantClass) {
    final got = h.eiClass == 1 ? '32-bit' : '64-bit';
    final want = wantClass == 1 ? '32-bit' : '64-bit';
    return 'built $got, target $triple needs $want';
  }

  if (elfArmHardFloat(triple) && (h.eFlags & _efArmAbiFloatHard) == 0) {
    return 'built soft-float, target $triple needs the hard-float ABI';
  }
  return null;
}
