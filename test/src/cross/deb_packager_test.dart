import 'dart:io';

import 'package:emb_cli/src/cross/deb_packager.dart';
import 'package:emb_cli/src/cross/process_runner.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('emb_deb_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  // A fake ProcessRunner standing in for readelf / chmod / dpkg-deb, capturing
  // the generated control file before the staging dir is removed.
  String? capturedControl;
  String? builtTo;
  // DEBIAN/ maintainer scripts captured from the staging dir before --build
  // removes it, plus the paths chmod was asked to make executable.
  Map<String, String>? capturedScripts;
  final chmodded = <String>[];
  final chmodArgs = <String>[];
  Future<RunResult> fakeRun(
    String exe,
    List<String> args, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool includeParentEnvironment = true,
    bool runInShell = false,
    ProcessOutputMode output = ProcessOutputMode.capture,
    String? label,
  }) async {
    if (exe.endsWith('readelf')) {
      return const RunResult(0, '''
 0x0000000000000001 (NEEDED) Shared library: [libc.so.6]
 0x0000000000000001 (NEEDED) Shared library: [libm.so.6]
 0x0000000000000001 (NEEDED) Shared library: [libgbm.so.1]
''', '');
    }
    if (exe == 'chmod') {
      chmodded.add(args.last);
      chmodArgs.add(args.join(' '));
      return const RunResult(0, '', '');
    }
    if (exe == 'dpkg-deb') {
      if (args.first == '-c') {
        return const RunResult(0, '''
-rwxr-xr-x root/root 100 2024-01-01 ./usr/lib/aarch64-linux-gnu/libgbm.so.1.0.0
lrwxrwxrwx root/root 0 2024-01-01 ./usr/lib/aarch64-linux-gnu/libgbm.so.1 -> libgbm.so.1.0.0
''', '');
      }
      if (args.first == '-f') return const RunResult(0, 'libgbm1\n', '');
      if (args.contains('--build')) {
        final stage = args[args.length - 2];
        capturedControl = File(
          p.join(stage, 'DEBIAN', 'control'),
        ).readAsStringSync();
        capturedScripts = {
          for (final name in DebPackager.maintainerScriptNames)
            if (File(p.join(stage, 'DEBIAN', name)).existsSync())
              name: File(p.join(stage, 'DEBIAN', name)).readAsStringSync(),
        };
        builtTo = args.last;
        File(args.last).writeAsStringSync('deb');
        return const RunResult(0, '', '');
      }
    }
    return const RunResult(0, '', '');
  }

  /// A sysroot whose dpkg db owns libc (provides libc.so.6 + libm.so.6).
  Directory fakeSysroot() {
    final sr = Directory(p.join(tmp.path, 'sysroot'));
    File(p.join(sr.path, 'var', 'lib', 'dpkg', 'info', 'libc6:arm64.list'))
      ..createSync(recursive: true)
      ..writeAsStringSync(
        '/usr/lib/aarch64-linux-gnu/libc.so.6\n'
        '/usr/lib/aarch64-linux-gnu/libm.so.6\n',
      );
    return sr;
  }

  File fakeBinary() =>
      File(p.join(tmp.path, 'homescreen'))
        ..writeAsBytesSync([0x7f, 0x45, 0x4c, 0x46, 0, 0, 0, 0]);

  test(
    'builds a .deb and auto-derives Depends from NEEDED + ownership',
    () async {
      // A non-empty .deb marker so the resolver-deb scan visits it.
      final debDir = Directory(p.join(tmp.path, 'debs'))..createSync();
      File(p.join(debDir.path, 'libgbm1_22_arm64.deb')).writeAsStringSync('x');

      final packager = DebPackager(
        readelf: '/x/aarch64-none-linux-gnu-readelf',
        runProcess: fakeRun,
      );
      final out = await packager.build(
        binary: fakeBinary(),
        installPath: '/usr/bin/homescreen',
        meta: const DebMetadata(
          name: 'ivi-homescreen',
          version: '1.0.0',
          architecture: 'arm64',
          maintainer: 'me <me@x>',
          description: 'IVI shell',
        ),
        outDir: Directory(p.join(tmp.path, 'dist')),
        sysroot: fakeSysroot(),
        debDirs: [debDir],
      );

      expect(out.path, endsWith('ivi-homescreen_1.0.0_arm64.deb'));
      expect(builtTo, out.path);
      expect(capturedControl, contains('Package: ivi-homescreen'));
      expect(capturedControl, contains('Architecture: arm64'));
      // libc.so.6 + libm.so.6 -> libc6 (dpkg db); libgbm.so.1 -> libgbm1 (deb).
      expect(capturedControl, contains('Depends: libc6, libgbm1'));
    },
  );

  test('autoDepends: false uses only the explicit Depends', () async {
    final packager = DebPackager(readelf: '/x/readelf', runProcess: fakeRun);
    await packager.build(
      binary: fakeBinary(),
      installPath: '/usr/bin/homescreen',
      meta: const DebMetadata(
        name: 'app',
        version: '0.1',
        architecture: 'arm64',
        maintainer: 'm <m@x>',
        description: 'd',
        autoDepends: false,
        dependsExtra: ['libfoo1'],
      ),
      outDir: Directory(p.join(tmp.path, 'dist')),
    );
    expect(capturedControl, contains('Depends: libfoo1'));
    expect(capturedControl, isNot(contains('libc6')));
  });

  test('rejects a relative install path', () async {
    final packager = DebPackager(readelf: '/x/readelf', runProcess: fakeRun);
    expect(
      () => packager.build(
        binary: fakeBinary(),
        installPath: 'usr/bin/homescreen',
        meta: const DebMetadata(
          name: 'app',
          version: '1',
          architecture: 'arm64',
          maintainer: 'm <m@x>',
          description: 'd',
        ),
        outDir: Directory(p.join(tmp.path, 'dist')),
      ),
      throwsA(isA<DebPackageException>()),
    );
  });

  test('stages maintainer scripts into DEBIAN/ as executables', () async {
    final postinst = File(p.join(tmp.path, 'postinst.sh'))
      ..writeAsStringSync('#!/bin/sh\nudevadm control --reload\n');
    final prerm = File(p.join(tmp.path, 'prerm.sh'))
      ..writeAsStringSync('#!/bin/sh\nsystemctl stop app\n');

    final packager = DebPackager(readelf: '/x/readelf', runProcess: fakeRun);
    await packager.build(
      binary: fakeBinary(),
      installPath: '/usr/bin/homescreen',
      meta: const DebMetadata(
        name: 'app',
        version: '1',
        architecture: 'arm64',
        maintainer: 'm <m@x>',
        description: 'd',
        autoDepends: false,
      ),
      outDir: Directory(p.join(tmp.path, 'dist')),
      maintainerScripts: {'postinst': postinst.path, 'prerm': prerm.path},
    );

    // Both scripts land under DEBIAN/ with their content; the others are absent.
    expect(capturedScripts!.keys, containsAll(['postinst', 'prerm']));
    expect(capturedScripts!['postinst'], contains('udevadm control --reload'));
    expect(capturedScripts!.containsKey('postrm'), isFalse);
    // Each staged script was chmod 0755'd.
    expect(chmodded.any((p) => p.endsWith('DEBIAN/postinst')), isTrue);
    expect(chmodded.any((p) => p.endsWith('DEBIAN/prerm')), isTrue);
  });

  test('applies an explicit per-file mode to an extra file', () async {
    final helper = File(p.join(tmp.path, 'helper'))..writeAsStringSync('#!sh');
    final packager = DebPackager(readelf: '/x/readelf', runProcess: fakeRun);
    await packager.build(
      binary: fakeBinary(),
      installPath: '/usr/bin/homescreen',
      meta: const DebMetadata(
        name: 'app',
        version: '1',
        architecture: 'arm64',
        maintainer: 'm <m@x>',
        description: 'd',
        autoDepends: false,
      ),
      outDir: Directory(p.join(tmp.path, 'dist')),
      extraFiles: {helper.path: '/usr/bin/helper'},
      fileModes: {helper.path: '0755'},
    );
    // The staged extra file was chmod 0755'd (separate from the binary's).
    expect(
      chmodArgs.any(
        (a) => a.startsWith('0755 ') && a.endsWith('usr/bin/helper'),
      ),
      isTrue,
    );
  });

  test('rejects an unknown maintainer script name', () async {
    final s = File(p.join(tmp.path, 's.sh'))..writeAsStringSync('#!/bin/sh\n');
    final packager = DebPackager(readelf: '/x/readelf', runProcess: fakeRun);
    expect(
      () => packager.build(
        binary: fakeBinary(),
        installPath: '/usr/bin/homescreen',
        meta: const DebMetadata(
          name: 'app',
          version: '1',
          architecture: 'arm64',
          maintainer: 'm <m@x>',
          description: 'd',
          autoDepends: false,
        ),
        outDir: Directory(p.join(tmp.path, 'dist')),
        maintainerScripts: {'postinstall': s.path},
      ),
      throwsA(isA<DebPackageException>()),
    );
  });
}
