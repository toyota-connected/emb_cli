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

  group('symbol-version gaps', () {
    /// A `readelf` stand-in answering both `-d` (NEEDED) and `-V` (version
    /// needs/definitions), keyed on basename. [needs] is per-file
    /// `soname -> versions required from it`; [defs] is per-file the versions
    /// that file defines.
    ProcessRunner readelfWithVersions({
      required Map<String, List<String>> needed,
      Map<String, Map<String, List<String>>> needs = const {},
      Map<String, List<String>> defs = const {},
    }) {
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
        final base = p.basename(args.last);
        if (args.contains('-V')) {
          final b = StringBuffer();
          final defined = defs[base];
          if (defined != null) {
            b
              ..writeln(
                "Version definition section '.gnu.version_d' contains "
                '${defined.length + 1} entries:',
              )
              ..writeln(
                '  000000: Rev: 1  Flags: BASE  Index: 1  Cnt: 1  '
                'Name: $base',
              );
            for (final v in defined) {
              b.writeln(
                '  0x001c: Rev: 1  Flags: none  Index: 2  Cnt: 1  '
                'Name: $v',
              );
            }
          }
          final required = needs[base];
          if (required != null) {
            b.writeln(
              "Version needs section '.gnu.version_r' contains "
              '${required.length} entries:',
            );
            for (final e in required.entries) {
              b.writeln(
                '  000000: Version: 1  File: ${e.key}  '
                'Cnt: ${e.value.length}',
              );
              for (final v in e.value) {
                b.writeln('  0x0030:   Name: $v  Flags: none  Version: 13');
              }
            }
          }
          return RunResult(0, b.toString(), '');
        }
        final sonames = needed[base] ?? const <String>[];
        return RunResult(
          0,
          sonames.map((s) => ' 0x01 (NEEDED)  Shared library: [$s]').join('\n'),
          '',
        );
      };
    }

    Future<VendorReport> run({
      required Map<String, Map<String, List<String>>> needs,
      required Map<String, List<String>> defs,
    }) async {
      final bundle = dir('runnable');
      elf('runnable/homescreen');
      Directory(p.join(bundle.path, 'lib')).createSync();
      elf('runtime/files/lib/aarch64-linux-gnu/libc.so.6');
      elf('sysroot/usr/lib/aarch64-linux-gnu/libinput.so.10');
      return FlatpakLibVendor(
        readelf: 'readelf',
        triple: triple,
        runProcess: readelfWithVersions(
          needed: {
            'homescreen': ['libc.so.6', 'libinput.so.10'],
          },
          needs: needs,
          defs: defs,
        ),
      ).vendor(
        bundleDir: bundle,
        command: 'homescreen',
        runtimeFiles: dir('runtime/files'),
        searchPaths: [dir('sysroot/usr/lib')],
      );
    }

    test(
      'a staged lib needing a newer glibc than the runtime is reported',
      () async {
        // #224: verifyElfForTriple passes a host library built against a newer
        // glibc, and with --target local the search root falls back to `/`, so
        // this is the ordinary case. It dies at startup inside the sandbox.
        final report = await run(
          needs: {
            'libinput.so.10': {
              'libc.so.6': ['GLIBC_2.38', 'GLIBC_2.17'],
            },
          },
          defs: {
            'libc.so.6': ['GLIBC_2.17', 'GLIBC_2.36'],
          },
        );
        expect(report.staged, contains('libinput.so.10'));
        expect(report.symbolGaps, [
          (staged: 'libinput.so.10', from: 'libc.so.6', version: 'GLIBC_2.38'),
        ]);
      },
    );

    test('a requirement the runtime defines is not reported', () async {
      final report = await run(
        needs: {
          'libinput.so.10': {
            'libc.so.6': ['GLIBC_2.17'],
          },
        },
        defs: {
          'libc.so.6': ['GLIBC_2.17', 'GLIBC_2.36'],
        },
      );
      expect(report.symbolGaps, isEmpty);
    });

    test('a non-ordered version name is handled by membership', () async {
      // GLIBC_ABI_DT_RELR has no position in a numeric ordering; the loader
      // resolves it by name, and so does this.
      final report = await run(
        needs: {
          'libinput.so.10': {
            'libc.so.6': ['GLIBC_ABI_DT_RELR'],
          },
        },
        defs: {
          'libc.so.6': ['GLIBC_2.17'],
        },
      );
      expect(report.symbolGaps.single.version, 'GLIBC_ABI_DT_RELR');
    });

    test(
      'a requirement on a library the runtime does not ship is skipped',
      () async {
        // Either it was vendored alongside, and its own copy satisfies it, or
        // nothing provides it and `unresolved` already says so.
        final report = await run(
          needs: {
            'libinput.so.10': {
              'libmystery.so.3': ['MYSTERY_1.0'],
            },
          },
          defs: {
            'libc.so.6': ['GLIBC_2.17'],
          },
        );
        expect(report.symbolGaps, isEmpty);
      },
    );

    test('a runtime library with no version defs produces no gap', () async {
      // Covers both ways of learning nothing: readelf failing, and a library
      // with no .gnu.version_d. Comparing against an empty set would invent a
      // gap for every requirement. The arch check is a hard skip; this one is
      // advisory, so silence is the safer default.
      final report = await run(
        needs: {
          'libinput.so.10': {
            'libc.so.6': ['GLIBC_2.38'],
          },
        },
        defs: const {},
      );
      expect(report.symbolGaps, isEmpty);
    });
  });
}
