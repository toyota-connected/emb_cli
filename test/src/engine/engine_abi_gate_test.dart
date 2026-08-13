import 'dart:io';

import 'package:emb_cli/src/engine/engine_abi_gate.dart';
import 'package:emb_cli/src/engine/engine_toolchain.dart';
import 'package:test/test.dart';

/// A fake `readelf`/`nm` returning canned output keyed by the flavour of call.
AbiToolRunner _canned({
  required String header,
  required String dynamicSection,
  required String defined,
  required String undefined,
}) {
  return (exe, args) async {
    final String out;
    if (args.contains('-h')) {
      out = header;
    } else if (args.contains('--defined-only')) {
      out = defined;
    } else if (args.contains('-u')) {
      out = undefined;
    } else {
      out = dynamicSection;
    }
    return ProcessResult(0, 0, out, '');
  };
}

void main() {
  final so = File('libflutter_engine.so');

  test('a self-contained glibc/arm64 lib passes all rules', () async {
    final gate = EngineAbiGate(
      runProcess: _canned(
        header: 'ELF Header:\n  Machine: AArch64',
        dynamicSection:
            ' (NEEDED) Shared library: [libc.so.6]\n'
            ' (NEEDED) Shared library: [libm.so.6]',
        defined:
            '0000000000012345 T FlutterEngineRun\n'
            '0000000000012346 T FlutterEngineInitialize',
        undefined:
            '                 U memcpy\n                 U pthread_create',
      ),
    );
    final v = await gate.verify(
      so,
      profile: ToolchainProfile.linuxGlibc,
      arch: 'arm64',
    );
    expect(v, isEmpty);
  });

  test(
    'flags linked C++ runtime, leaked/undefined C++ symbols, and libgcc_s',
    () async {
      final gate = EngineAbiGate(
        runProcess: _canned(
          header: 'ELF Header:\n  Machine: AArch64',
          dynamicSection:
              ' (NEEDED) Shared library: [libstdc++.so.6]\n'
              ' (NEEDED) Shared library: [libc.so.6]\n'
              ' (NEEDED) Shared library: [libgcc_s.so.1]',
          defined:
              '0000000000012345 T FlutterEngineRun\n'
              '0000000000012346 T _ZN3fml6RefPtr',
          undefined:
              '                 U __cxa_throw\n'
              '                 U _Unwind_Resume',
        ),
      );
      final v = await gate.verify(
        so,
        profile: ToolchainProfile.linuxGlibc,
        arch: 'arm64',
      );
      final rules = v.map((x) => x.rule).toSet();
      expect(rules, containsAll(<int>[2, 4, 5, 6]));
    },
  );

  test('rule 3 fires when a glibc lib is used for a musl profile', () async {
    final gate = EngineAbiGate(
      runProcess: _canned(
        header: 'ELF Header:\n  Machine: AArch64',
        dynamicSection: ' (NEEDED) Shared library: [libc.so.6]',
        defined: '0000000000012345 T FlutterEngineRun',
        undefined: '                 U memcpy',
      ),
    );
    final v = await gate.verify(
      so,
      profile: const ToolchainProfile(os: TargetOs.linux, libc: Libc.musl),
      arch: 'arm64',
    );
    expect(v.map((x) => x.rule), contains(3));
  });

  test('rule 1 fires on an arch mismatch', () async {
    final gate = EngineAbiGate(
      runProcess: _canned(
        header: 'ELF Header:\n  Machine: X86-64',
        dynamicSection: ' (NEEDED) Shared library: [libc.so.6]',
        defined: '0000000000012345 T FlutterEngineRun',
        undefined: '                 U memcpy',
      ),
    );
    final v = await gate.verify(
      so,
      profile: ToolchainProfile.linuxGlibc,
      arch: 'arm64',
    );
    expect(v.map((x) => x.rule), contains(1));
  });

  group('arch machine detection (cross arches)', () {
    const cases = {
      'x86_64': 'X86-64',
      'arm64': 'AArch64',
      'armv7hf': 'ARM',
      'riscv64': 'RISC-V',
    };
    for (final entry in cases.entries) {
      test('${entry.key} matches ELF machine ${entry.value}', () async {
        final gate = EngineAbiGate(
          runProcess: _canned(
            header: 'ELF Header:\n  Machine: ${entry.value}',
            dynamicSection: ' (NEEDED) Shared library: [libc.so.6]',
            defined: '0000000000012345 T FlutterEngineRun',
            undefined: '                 U memcpy',
          ),
        );
        final v = await gate.verify(
          so,
          profile: ToolchainProfile.linuxGlibc,
          arch: entry.key,
        );
        expect(v.where((x) => x.rule == 1), isEmpty);
      });
    }
  });

  test('a musl profile passes against a musl-linked lib', () async {
    final gate = EngineAbiGate(
      runProcess: _canned(
        header: 'ELF Header:\n  Machine: AArch64',
        dynamicSection: ' (NEEDED) Shared library: [libc.musl-aarch64.so.1]',
        defined: '0000000000012345 T FlutterEngineRun',
        undefined: '                 U memcpy',
      ),
    );
    final v = await gate.verify(
      so,
      profile: const ToolchainProfile(
        os: TargetOs.linux,
        libc: Libc.musl,
        sysrootId: 'alpine',
      ),
      arch: 'arm64',
    );
    expect(v, isEmpty);
  });

  test('the unversioned libc __cxa_atexit family does not trip rule 6 (musl), '
      'but a real libc++abi symbol still does', () async {
    const musl = ToolchainProfile(
      os: TargetOs.linux,
      libc: Libc.musl,
      sysrootId: 'alpine',
    );
    // musl carries no symbol version, so __cxa_atexit / __cxa_finalize /
    // __cxa_thread_atexit_impl (libc's static-destructor registration) arrive
    // unversioned — they must not be mistaken for a C++ ABI dependency.
    final libc = EngineAbiGate(
      runProcess: _canned(
        header: 'ELF Header:\n  Machine: AArch64',
        dynamicSection: ' (NEEDED) Shared library: [libc.musl-aarch64.so.1]',
        defined: '0000000000012345 T FlutterEngineRun',
        undefined:
            '                 U __cxa_atexit\n'
            '                 U __cxa_finalize\n'
            '                 U __cxa_thread_atexit_impl',
      ),
    );
    final quiet = await libc.verify(so, profile: musl, arch: 'arm64');
    expect(quiet.where((x) => x.rule == 6), isEmpty);

    // A genuine unversioned libc++abi dependency must still fire rule 6.
    final bad = EngineAbiGate(
      runProcess: _canned(
        header: 'ELF Header:\n  Machine: AArch64',
        dynamicSection: ' (NEEDED) Shared library: [libc.musl-aarch64.so.1]',
        defined: '0000000000012345 T FlutterEngineRun',
        undefined: '                 U __cxa_throw',
      ),
    );
    final loud = await bad.verify(so, profile: musl, arch: 'arm64');
    expect(loud.map((x) => x.rule), contains(6));
  });
}
