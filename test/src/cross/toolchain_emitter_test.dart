import 'dart:io';

import 'package:emb_cli/src/cross/toolchain_emitter.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  const emitter = ToolchainEmitter();
  setUp(() => tmp = Directory.systemTemp.createTempSync('emb_emit_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('emitCMake writes the expected toolchain shape', () {
    final path = emitter.emitCMake(
      outDir: tmp,
      triple: 'aarch64-none-linux-gnu',
      crossBin: '/tc/bin',
      sysroot: '/sr',
      cpuFlags: ['-mcpu=cortex-a76'],
    );
    final text = File(path).readAsStringSync();
    expect(path, endsWith('aarch64-none-linux-gnu-toolchain.cmake'));
    expect(text, contains('set(CMAKE_SYSTEM_NAME      Linux)'));
    expect(text, contains('"/tc/bin"'));
    expect(text, contains('aarch64-none-linux-gnu-gcc'));
    expect(text, contains('"/sr"'));
    expect(text, contains('-mcpu=cortex-a76'));
    expect(text, contains('set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)'));
    expect(text, contains('set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)'));
  });

  test('emitMeson writes binaries + host_machine + cross args', () {
    final path = emitter.emitMeson(
      outDir: tmp,
      triple: 'aarch64-poky-linux',
      crossBin: '/tc/bin',
      sysroot: '/sr',
      cpuFlags: ['-march=armv8-a+crc+crypto'],
    );
    final text = File(path).readAsStringSync();
    expect(path, endsWith('aarch64-poky-linux-meson.cross'));
    expect(text, contains("c = '/tc/bin/aarch64-poky-linux-gcc'"));
    expect(text, contains('cpu_family = '));
    expect(text, contains('--sysroot=/sr'));
    expect(text, contains("'-march=armv8-a+crc+crypto'"));
    // No exe_wrapper directive: emb cross builds never execute freshly-built
    // target binaries during the build, so the cross file must not pull in a
    // qemu-user emulator (an explanatory comment may still mention it).
    expect(text, isNot(contains('exe_wrapper =')));
    expect(text, isNot(contains('qemu-aarch64-static')));
  });

  // The sysroot's multiarch include is a system header directory and reaches
  // the compiler as -isystem, so a project's own headers outrank it. Meson
  // keeps compile and link args separate: the crt/library search flags belong
  // in both, the include flags only in the compile args.
  test('emitMeson keeps include flags out of the link args', () {
    final path = emitter.emitMeson(
      outDir: tmp,
      triple: 'aarch64-none-linux-gnu',
      crossBin: '/tc/bin',
      sysroot: '/sr',
      cpuFlags: [
        '-mcpu=cortex-a76',
        '-B/sr/usr/lib/aarch64-linux-gnu',
        '-L/sr/usr/lib/aarch64-linux-gnu',
        '-isystem/sr/usr/include/aarch64-linux-gnu',
        '-I/sr/opt/include',
      ],
    );
    final text = File(path).readAsStringSync();
    String lineStartingWith(String prefix) => text
        .split('\n')
        .firstWhere((l) => l.startsWith(prefix), orElse: () => '');

    final compileArgs = lineStartingWith('c_args = ');
    final linkArgs = lineStartingWith('c_link_args = ');
    expect(compileArgs, isNotEmpty);
    expect(linkArgs, isNotEmpty);

    expect(
      compileArgs,
      contains('-isystem/sr/usr/include/aarch64-linux-gnu'),
    );
    expect(compileArgs, contains('-I/sr/opt/include'));
    // Both include forms are compile-only; -B and -L are not.
    expect(linkArgs, isNot(contains('-isystem')));
    expect(linkArgs, isNot(contains('-I/sr/opt/include')));
    expect(linkArgs, contains('-B/sr/usr/lib/aarch64-linux-gnu'));
    expect(linkArgs, contains('-L/sr/usr/lib/aarch64-linux-gnu'));
  });

  test('derives system processor / cpu_family from the triple (riscv64)', () {
    const triple = 'riscv64-unknown-linux-gnu';
    final cmake = File(
      emitter.emitCMake(
        outDir: tmp,
        triple: triple,
        crossBin: '/tc/bin',
        sysroot: '/sr',
        cpuFlags: const [],
      ),
    ).readAsStringSync();
    expect(cmake, contains('set(CMAKE_SYSTEM_PROCESSOR riscv64)'));
    final meson = File(
      emitter.emitMeson(
        outDir: tmp,
        triple: triple,
        crossBin: '/tc/bin',
        sysroot: '/sr',
        cpuFlags: const [],
      ),
    ).readAsStringSync();
    expect(meson, contains("cpu_family = 'riscv64'"));
  });

  test('emitMeson omits tuning args when cpuFlags is empty', () {
    final path = emitter.emitMeson(
      outDir: tmp,
      triple: 'aarch64-poky-linux',
      crossBin: '/tc/bin',
      sysroot: '/sr',
      cpuFlags: const [],
    );
    final text = File(path).readAsStringSync();
    // Only the sysroot and the prefix-map remain; no cpu tuning.
    const expected =
        "c_args = ['--sysroot=/sr', '-ffile-prefix-map=/sr=/emb/sysroot'";
    expect(text, contains(expected));
    expect(text, isNot(contains('-mcpu')));
  });
}
