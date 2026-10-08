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

/// Parse the `DT_NEEDED` shared-library sonames out of `readelf -d` output.
///
/// Each dynamic-section `NEEDED` entry prints as
/// `0x… (NEEDED)  Shared library: [libfoo.so.1]`; this pulls the bracketed
/// sonames in file order. Used both to compute a package's auto-`Depends` and
/// to decide which project-built libraries ride along in a runnable bundle.
List<String> parseNeededSonames(String readelfOutput) {
  final re = RegExp(r'Shared library:\s*\[([^\]]+)\]');
  return [for (final m in re.allMatches(readelfOutput)) m.group(1)!];
}

/// Parse the symbol-version *requirements* out of `readelf -V` output: which
/// versioned symbol names this object needs, grouped by the library expected to
/// define them.
///
/// The `.gnu.version_r` section prints one group per library, each followed by
/// its required version names:
///
/// ```text
///   000000: Version: 1  File: libc.so.6  Cnt: 12
///   0x0030:   Name: GLIBC_2.28  Flags: none  Version: 13
///   0x0040:   Name: GLIBC_2.38  Flags: none  Version: 12
/// ```
///
/// A `Name:` line is attributed to the most recent `File:`, which is how the
/// format nests. Lines outside the needs section are ignored — `readelf -V`
/// also prints `.gnu.version` (a per-symbol index table) and
/// `.gnu.version_d` (definitions), and both carry `Name:` text that would
/// otherwise be read as a requirement.
Map<String, Set<String>> parseVersionNeeds(String readelfOutput) {
  final needs = <String, Set<String>>{};
  final file = RegExp(r'File:\s*(\S+)');
  final name = RegExp(r'Name:\s*(\S+)');
  var inNeeds = false;
  String? current;
  for (final line in readelfOutput.split('\n')) {
    if (line.contains('section')) {
      // A new section heading ends the previous one, so a `Name:` after the
      // definitions heading is never credited to a file seen before it.
      inNeeds = line.contains('.gnu.version_r');
      current = null;
      continue;
    }
    if (!inNeeds) continue;
    final f = file.firstMatch(line);
    if (f != null) {
      current = f.group(1);
      needs.putIfAbsent(current!, () => <String>{});
      continue;
    }
    if (current == null) continue;
    final n = name.firstMatch(line);
    if (n != null) needs[current]!.add(n.group(1)!);
  }
  return needs;
}

/// Parse the symbol-version *definitions* out of `readelf -V` output: the
/// version names this object provides.
///
/// The `.gnu.version_d` section prints one entry per version:
///
/// ```text
///   000000: Rev: 1  Flags: BASE  Index: 1  Cnt: 1  Name: libc.so.6
///   0x001c: Rev: 1  Flags: none  Index: 2  Cnt: 1  Name: GLIBC_2.2.5
/// ```
///
/// The `BASE` entry names the library itself rather than a version, and
/// `Parent N:` lines restate a name already listed, so both are skipped.
Set<String> parseVersionDefs(String readelfOutput) {
  final defs = <String>{};
  final name = RegExp(r'Name:\s*(\S+)');
  var inDefs = false;
  for (final line in readelfOutput.split('\n')) {
    if (line.contains('section')) {
      inDefs = line.contains('.gnu.version_d');
      continue;
    }
    if (!inDefs || line.contains('Flags: BASE')) continue;
    final m = name.firstMatch(line);
    if (m != null) defs.add(m.group(1)!);
  }
  return defs;
}
