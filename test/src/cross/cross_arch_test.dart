import 'package:emb_cli/src/cross/cross_arch.dart';
import 'package:test/test.dart';

void main() {
  test('archOfTriple takes the first triple segment, lowercased', () {
    expect(archOfTriple('aarch64-none-linux-gnu'), 'aarch64');
    expect(archOfTriple('arm-none-linux-gnueabihf'), 'arm');
    expect(archOfTriple('RISCV64-poky-linux'), 'riscv64');
  });

  test('cpuFamilyOfTriple maps to meson/cmake families (not just aarch64)', () {
    expect(cpuFamilyOfTriple('aarch64-poky-linux'), 'aarch64');
    expect(cpuFamilyOfTriple('arm-none-linux-gnueabihf'), 'arm');
    expect(cpuFamilyOfTriple('riscv64-unknown-linux-gnu'), 'riscv64');
    expect(cpuFamilyOfTriple('x86_64-linux-gnu'), 'x86_64');
  });

  test('debianMultiarch maps to the right tuple', () {
    expect(debianMultiarch('aarch64-none-linux-gnu'), 'aarch64-linux-gnu');
    expect(debianMultiarch('arm-none-linux-gnueabihf'), 'arm-linux-gnueabihf');
    expect(debianMultiarch('riscv64-poky-linux'), 'riscv64-linux-gnu');
    expect(debianMultiarch('x86_64-linux-gnu'), 'x86_64-linux-gnu');
  });

  test('debianArch maps to the dpkg arch name', () {
    expect(debianArch('aarch64-none-linux-gnu'), 'arm64');
    expect(debianArch('arm-none-linux-gnueabihf'), 'armhf');
    expect(debianArch('riscv64-poky-linux'), 'riscv64');
    expect(debianArch('x86_64-linux-gnu'), 'amd64');
  });

  test('rustTriple maps a GNU triple to its Rust target', () {
    expect(rustTriple('aarch64-none-linux-gnu'), 'aarch64-unknown-linux-gnu');
    expect(
      rustTriple('arm-none-linux-gnueabihf'),
      'armv7-unknown-linux-gnueabihf',
    );
    expect(rustTriple('riscv64-poky-linux'), 'riscv64gc-unknown-linux-gnu');
    expect(rustTriple('x86_64-linux-gnu'), 'x86_64-unknown-linux-gnu');
  });
}
