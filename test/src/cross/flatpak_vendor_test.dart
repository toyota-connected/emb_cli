import 'dart:io';
import 'dart:typed_data';

import 'package:emb_cli/src/cross/flatpak_vendor.dart';
import 'package:emb_cli/src/cross/process_runner.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// A 64-byte little-endian ELF header for [eMachine] — enough for the arch
/// check the vendor does before staging a candidate.
Uint8List _elf({int eMachine = 0xB7}) {
  final b = Uint8List(64);
  b[0] = 0x7f;
  b[1] = 0x45;
  b[2] = 0x4c;
  b[3] = 0x46;
  b[4] = 2; // ELFCLASS64
  b[5] = 1; // little-endian
  ByteData.sublistView(b).setUint16(18, eMachine, Endian.little);
  return b;
}

void main() {
  const triple = 'aarch64-linux-gnu';
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('emb_fpvendor_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  Directory dir(String rel) =>
      Directory(p.join(tmp.path, rel))..createSync(recursive: true);

  File elf(String path, {int eMachine = 0xB7}) {
    final f = File(p.join(tmp.path, path));
    f.parent.createSync(recursive: true);
    return f..writeAsBytesSync(_elf(eMachine: eMachine));
  }

  /// `readelf -d` stand-in: each path maps to the sonames it NEEDs.
  ProcessRunner readelfReturning(Map<String, List<String>> needed) {
    return (
      String exe,
      List<String> args, {
      String? workingDirectory,
      Map<String, String>? environment,
      bool includeParentEnvironment = true,
      bool runInShell = false,
      ProcessOutputMode output = ProcessOutputMode.capture,
      String? label,
    }) async {
      final sonames = needed[p.basename(args.last)] ?? const <String>[];
      final out = sonames
          .map((s) => ' 0x01 (NEEDED)  Shared library: [$s]')
          .join('\n');
      return RunResult(0, out, '');
    };
  }

  test('vendors only what the runtime does not provide', () async {
    final bundle = dir('runnable');
    elf('runnable/homescreen');
    Directory(p.join(bundle.path, 'lib')).createSync();

    // The runtime has libc; it does not have libinput.
    elf('runtime/files/lib/aarch64-linux-gnu/libc.so.6');
    // The sysroot has both, as a build sysroot does.
    elf('sysroot/usr/lib/aarch64-linux-gnu/libc.so.6');
    elf('sysroot/usr/lib/aarch64-linux-gnu/libinput.so.10');

    final report =
        await FlatpakLibVendor(
          readelf: 'readelf',
          triple: triple,
          runProcess: readelfReturning({
            'homescreen': ['libc.so.6', 'libinput.so.10', 'linux-vdso.so.1'],
          }),
        ).vendor(
          bundleDir: bundle,
          command: 'homescreen',
          runtimeFiles: Directory(p.join(tmp.path, 'runtime/files')),
          searchPaths: [Directory(p.join(tmp.path, 'sysroot/usr/lib'))],
        );

    expect(report.staged, ['libinput.so.10']);
    expect(report.provided, ['libc.so.6']);
    expect(report.unresolved, isEmpty);
    expect(
      File(p.join(bundle.path, 'lib', 'libinput.so.10')).existsSync(),
      isTrue,
    );
    // The runtime's own libc must not be shadowed by a second copy.
    expect(File(p.join(bundle.path, 'lib', 'libc.so.6')).existsSync(), isFalse);
  });

  test('follows a vendored library into its own dependencies', () async {
    final bundle = dir('runnable');
    elf('runnable/homescreen');
    dir('runtime/files/lib');
    elf('sysroot/lib/libinput.so.10');
    elf('sysroot/lib/libudev.so.1');

    final report =
        await FlatpakLibVendor(
          readelf: 'readelf',
          triple: triple,
          runProcess: readelfReturning({
            'homescreen': ['libinput.so.10'],
            'libinput.so.10': ['libudev.so.1'],
          }),
        ).vendor(
          bundleDir: bundle,
          command: 'homescreen',
          runtimeFiles: Directory(p.join(tmp.path, 'runtime/files')),
          searchPaths: [Directory(p.join(tmp.path, 'sysroot/lib'))],
        );

    expect(report.staged, ['libinput.so.10', 'libudev.so.1']);
  });

  test('seeds from the bundle lib/, where the code assets are', () async {
    final bundle = dir('runnable');
    elf('runnable/homescreen');
    elf('runnable/lib/libflatpak_nc.so');
    dir('runtime/files/lib');
    elf('sysroot/lib/libflatpak.so.0');

    final report =
        await FlatpakLibVendor(
          readelf: 'readelf',
          triple: triple,
          runProcess: readelfReturning({
            'homescreen': const [],
            // A Dart build hook's code asset, not the embedder, needs this.
            'libflatpak_nc.so': ['libflatpak.so.0'],
          }),
        ).vendor(
          bundleDir: bundle,
          command: 'homescreen',
          runtimeFiles: Directory(p.join(tmp.path, 'runtime/files')),
          searchPaths: [Directory(p.join(tmp.path, 'sysroot/lib'))],
        );

    expect(report.staged, ['libflatpak.so.0']);
  });

  test(
    'recreates the soname symlink when the real file is versioned',
    () async {
      final bundle = dir('runnable');
      elf('runnable/homescreen');
      dir('runtime/files/lib');
      final real = elf('sysroot/lib/libinput.so.10.13.0');
      Link(
        p.join(tmp.path, 'sysroot/lib/libinput.so.10'),
      ).createSync(p.basename(real.path));

      final report =
          await FlatpakLibVendor(
            readelf: 'readelf',
            triple: triple,
            runProcess: readelfReturning({
              'homescreen': ['libinput.so.10'],
            }),
          ).vendor(
            bundleDir: bundle,
            command: 'homescreen',
            runtimeFiles: Directory(p.join(tmp.path, 'runtime/files')),
            searchPaths: [Directory(p.join(tmp.path, 'sysroot/lib'))],
          );

      expect(report.staged, ['libinput.so.10']);
      final libDir = p.join(bundle.path, 'lib');
      expect(File(p.join(libDir, 'libinput.so.10.13.0')).existsSync(), isTrue);
      expect(
        Link(p.join(libDir, 'libinput.so.10')).targetSync(),
        'libinput.so.10.13.0',
      );
    },
  );

  test('a host-arch library on the search path is not staged', () async {
    final bundle = dir('runnable');
    elf('runnable/homescreen');
    dir('runtime/files/lib');
    elf('sysroot/lib/libinput.so.10', eMachine: 0x3E); // x86-64

    final report =
        await FlatpakLibVendor(
          readelf: 'readelf',
          triple: triple,
          runProcess: readelfReturning({
            'homescreen': ['libinput.so.10'],
          }),
        ).vendor(
          bundleDir: bundle,
          command: 'homescreen',
          runtimeFiles: Directory(p.join(tmp.path, 'runtime/files')),
          searchPaths: [Directory(p.join(tmp.path, 'sysroot/lib'))],
        );

    // Better unresolved and warned about than a wrong-arch lib that links and
    // then fails at load.
    expect(report.staged, isEmpty);
    expect(report.unresolved, ['libinput.so.10']);
  });
  test('a lib already in the bundle beats the runtime index', () async {
    final bundle = dir('runnable');
    elf('runnable/homescreen');
    // The engine ships its own copy; the runtime happens to have one too.
    elf('runnable/lib/libfoo.so.1');
    elf('runtime/files/lib/libfoo.so.1');

    final report =
        await FlatpakLibVendor(
          readelf: 'readelf',
          triple: triple,
          runProcess: readelfReturning({
            'homescreen': ['libfoo.so.1'],
            'libfoo.so.1': const [],
          }),
        ).vendor(
          bundleDir: bundle,
          command: 'homescreen',
          runtimeFiles: Directory(p.join(tmp.path, 'runtime/files')),
          searchPaths: const [],
        );

    // $ORIGIN/lib is searched first, so the bundle's copy is what loads —
    // calling it runtime-provided would name the wrong file.
    expect(report.provided, isEmpty);
    expect(report.staged, isEmpty);
    expect(report.unresolved, isEmpty);
  });
  test('fails loudly when readelf reads nothing from the embedder', () async {
    final bundle = dir('runnable');
    elf('runnable/homescreen');
    dir('runtime/files/lib');

    // A missing or wrong-arch cross readelf: every invocation fails.
    Future<RunResult> broken(
      String exe,
      List<String> args, {
      String? workingDirectory,
      Map<String, String>? environment,
      bool includeParentEnvironment = true,
      bool runInShell = false,
      ProcessOutputMode output = ProcessOutputMode.capture,
      String? label,
    }) async => const RunResult(127, '', 'readelf: not found');

    // Reporting "0 vendored" as success here would ship a bundle that dies at
    // startup, so this has to be an error rather than an empty report.
    expect(
      FlatpakLibVendor(
        readelf: 'aarch64-none-linux-gnu-readelf',
        triple: triple,
        runProcess: broken,
      ).vendor(
        bundleDir: bundle,
        command: 'homescreen',
        runtimeFiles: Directory(p.join(tmp.path, 'runtime/files')),
        searchPaths: const [],
      ),
      throwsA(isA<FlatpakVendorException>()),
    );
  });
}
