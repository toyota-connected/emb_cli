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
    // Target binaries built during the cross run (codegen tools, `meson test`)
    // execute under qemu-user against the sysroot.
    expect(
      text,
      contains("exe_wrapper = ['qemu-aarch64-static', '-L', '/sr']"),
    );
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
    expect(text, contains("c_args = ['--sysroot=/sr']"));
  });
}
