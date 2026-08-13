import 'dart:io';

import 'package:emb_cli/src/engine/engine_toolchain.dart';

/// A subprocess runner (`readelf` / `nm`), injectable for tests.
typedef AbiToolRunner =
    Future<ProcessResult> Function(String exe, List<String> args);

/// A single ABI-gate rule violation. [rule] is the rule number from
///.
class AbiViolation {
  const AbiViolation(this.rule, this.detail);

  final int rule;
  final String detail;

  @override
  String toString() => 'ABI[rule $rule]: $detail';
}

/// Verifies that a staged `libflutter_engine.so` is a self-contained,
/// C-ABI-clean drop-in for the target `(os, libc)` — so a clang-built engine is
/// safe inside a GCC/musl userland. Fail-closed.
class EngineAbiGate {
  EngineAbiGate({
    AbiToolRunner? runProcess,
    String readelf = 'readelf',
    String nm = 'nm',
  }) : _run = runProcess ?? _defaultRunner,
       _readelf = readelf,
       _nm = nm;

  final AbiToolRunner _run;
  final String _readelf;
  final String _nm;

  static Future<ProcessResult> _defaultRunner(String exe, List<String> args) =>
      Process.run(exe, args);

  static final RegExp _cxxRuntime = RegExp(
    r'libstdc\+\+|libc\+\+abi|libc\+\+\.so',
  );
  static final RegExp _muslLibc = RegExp(r'ld-musl-|libc\.musl-');
  static final RegExp _glibcLibc = RegExp(r'libc\.so\.6');
  static final RegExp _exportedCxx = RegExp('^_Z');
  static final RegExp _externCxx = RegExp(
    '^(?:__cxa_|__cxxabiv1|__gxx_personality|_ZSt|_ZNSt|_Zna|_Znw|_ZdlPv)',
  );
  static final Map<String, RegExp> _machineFor = {
    'x86_64': RegExp('X86-64'),
    'arm64': RegExp('AArch64'),
    'armv7hf': RegExp(r'\bARM\b'),
    'riscv64': RegExp('RISC-V'),
  };

  /// Returns the violations for [so]; an empty list is a pass.
  Future<List<AbiViolation>> verify(
    File so, {
    required ToolchainProfile profile,
    required String arch,
  }) async {
    final violations = <AbiViolation>[];

    // Rule 1: the ELF targets the expected machine.
    final header = await _text(_readelf, ['-h', so.path]);
    final wantMachine = _machineFor[arch];
    if (wantMachine != null && !wantMachine.hasMatch(header)) {
      violations.add(
        AbiViolation(
          1,
          'arch mismatch: want $arch, got "${_machineLine(header)}"',
        ),
      );
    }

    final needed = _neededFrom(await _text(_readelf, ['-d', so.path]));

    // Rule 2: no C++ runtime dynamically linked.
    final cxxRt = needed.where(_cxxRuntime.hasMatch).toList();
    if (cxxRt.isNotEmpty) {
      violations.add(
        AbiViolation(2, 'links a C++ runtime: ${cxxRt.join(", ")}'),
      );
    }

    // Rule 3: libc matches the profile.
    final hasMusl = needed.any(_muslLibc.hasMatch);
    final hasGlibc = needed.any(_glibcLibc.hasMatch);
    switch (profile.libc) {
      case Libc.musl:
        if (!hasMusl || hasGlibc) {
          violations.add(AbiViolation(3, 'expected musl libc, NEEDED=$needed'));
        }
      case Libc.glibc:
        if (!hasGlibc || hasMusl) {
          violations.add(
            AbiViolation(3, 'expected glibc libc, NEEDED=$needed'),
          );
        }
      case Libc.bionic:
        // The bionic profile lands with the Android pipeline.
        break;
    }

    // Rule 4: self-contained unwinder.
    if (needed.any((n) => n.contains('libgcc_s'))) {
      violations.add(
        const AbiViolation(4, 'dynamic libgcc_s — unwinder not static'),
      );
    }

    // Rule 5: no exported (defined) C++ symbols — the internal libc++ must
    // not leak.
    final defined = _symbols(
      await _text(_nm, ['-D', '--defined-only', so.path]),
    );
    final leaked = defined.where(_exportedCxx.hasMatch).take(5).toList();
    if (leaked.isNotEmpty) {
      violations.add(
        AbiViolation(
          5,
          'exported C++ symbols leak libc++: ${leaked.join(", ")}…',
        ),
      );
    }

    // Rule 6: no undefined C++-runtime symbols that would pull libstdc++/libc++abi.
    // Symbols versioned against @GLIBC_ are provided by libc.so.6 (an allowed
    // NEEDED), so exclude them: glibc owns the C-runtime __cxa_atexit /
    // __cxa_finalize / __cxa_thread_atexit_impl family, which shares the __cxa_
    // prefix but is not a C++ ABI dependency. Genuine libstdc++/libc++abi pulls
    // are unversioned _Z*/__cxa_* or carry @GLIBCXX_/@CXXABI_, still caught.
    final undef = _symbols(await _text(_nm, ['-D', '-u', so.path]));
    final ext = undef
        .where((s) => !s.contains('@GLIBC_'))
        .where(_externCxx.hasMatch)
        .take(5)
        .toList();
    if (ext.isNotEmpty) {
      violations.add(
        AbiViolation(
          6,
          'undefined C++-runtime deps require libstdc++/libc++abi: ${ext.join(", ")}',
        ),
      );
    }
    if (undef.any((s) => s.startsWith('_Unwind_'))) {
      violations.add(
        const AbiViolation(
          4,
          'undefined _Unwind_* — needs an external unwinder',
        ),
      );
    }

    return violations;
  }

  Future<String> _text(String exe, List<String> args) async {
    final result = await _run(exe, args);
    final out = result.stdout;
    return out is String ? out : '$out';
  }

  static String _machineLine(String header) {
    for (final line in header.split('\n')) {
      if (line.contains('Machine:')) return line.split('Machine:').last.trim();
    }
    return '?';
  }

  static List<String> _neededFrom(String readelfDynamic) {
    final re = RegExp(r'NEEDED.*\[(.+?)\]');
    return [
      for (final line in readelfDynamic.split('\n'))
        if (re.firstMatch(line) case final m?) m.group(1)!,
    ];
  }

  static List<String> _symbols(String nmOut) {
    final out = <String>[];
    for (final line in nmOut.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      out.add(trimmed.split(RegExp(r'\s+')).last);
    }
    return out;
  }
}
