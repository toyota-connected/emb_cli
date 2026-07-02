import 'dart:io';

import 'package:emb_cli/src/cross/ipk_packager.dart';
import 'package:emb_cli/src/cross/process_runner.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('emb_ipk_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  // A fake ProcessRunner standing in for command/chmod/opkg-build, capturing
  // the staged CONTROL/ tree before opkg-build would remove it.
  String? capturedControl;
  Map<String, String>? capturedScripts;
  List<String>? opkgArgv;
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
    if (exe == 'command') {
      return const RunResult(0, '/usr/bin/opkg-build\n', '');
    }
    if (exe == 'chmod') return const RunResult(0, '', '');
    if (exe == 'opkg-build') {
      opkgArgv = args;
      final stage = args[args.length - 2];
      capturedControl = File(
        p.join(stage, 'CONTROL', 'control'),
      ).readAsStringSync();
      capturedScripts = {
        for (final name in ['preinst', 'postinst', 'prerm', 'postrm'])
          if (File(p.join(stage, 'CONTROL', name)).existsSync())
            name: File(p.join(stage, 'CONTROL', name)).readAsStringSync(),
      };
      // opkg-build writes <name>_<version>_<arch>.ipk into the dest dir.
      final dest = args.last;
      File(
        p.join(dest, 'ivi-homescreen_1.0.0_aarch64.ipk'),
      ).writeAsStringSync('ipk');
      return const RunResult(0, '', '');
    }
    return const RunResult(0, '', '');
  }

  File fakeBinary() =>
      File(p.join(tmp.path, 'homescreen'))
        ..writeAsBytesSync([0x7f, 0x45, 0x4c, 0x46, 0, 0, 0, 0]);

  test('builds an .ipk with a deb-style control file', () async {
    final packager = IpkPackager(runProcess: fakeRun);
    final out = await packager.build(
      binary: fakeBinary(),
      installPath: '/usr/bin/homescreen',
      meta: const IpkMetadata(
        name: 'ivi-homescreen',
        version: '1.0.0',
        architecture: 'aarch64',
        maintainer: 'me <me@x>',
        description: 'IVI shell',
        section: 'utils',
        depends: ['libc6', 'libgbm1'],
      ),
      outDir: Directory(p.join(tmp.path, 'dist')),
    );

    expect(out.path, endsWith('ivi-homescreen_1.0.0_aarch64.ipk'));
    expect(capturedControl, contains('Package: ivi-homescreen'));
    expect(capturedControl, contains('Architecture: aarch64'));
    // Explicit depends are emitted, sorted.
    expect(capturedControl, contains('Depends: libc6, libgbm1'));
    // opkg-build is invoked root-free against the staged CONTROL/ tree.
    expect(opkgArgv, containsAll(['-o', 'root', '-g', 'root']));
  });

  test('stages maintainer scripts into CONTROL/', () async {
    final postinst = File(p.join(tmp.path, 'postinst'))
      ..writeAsStringSync('#!/bin/sh\nopkg_reload\n');
    final packager = IpkPackager(runProcess: fakeRun);
    await packager.build(
      binary: fakeBinary(),
      installPath: '/usr/bin/homescreen',
      meta: const IpkMetadata(
        name: 'ivi-homescreen',
        version: '1.0.0',
        architecture: 'aarch64',
        maintainer: 'me <me@x>',
        description: 'd',
      ),
      outDir: Directory(p.join(tmp.path, 'dist')),
      maintainerScripts: {'postinst': postinst.path},
    );
    expect(capturedScripts!.keys, ['postinst']);
    expect(capturedScripts!['postinst'], contains('opkg_reload'));
  });

  test('rejects a relative install path', () async {
    final packager = IpkPackager(runProcess: fakeRun);
    expect(
      () => packager.build(
        binary: fakeBinary(),
        installPath: 'usr/bin/homescreen',
        meta: const IpkMetadata(
          name: 'app',
          version: '1',
          architecture: 'aarch64',
          maintainer: 'm <m@x>',
          description: 'd',
        ),
        outDir: Directory(p.join(tmp.path, 'dist')),
      ),
      throwsA(isA<IpkPackageException>()),
    );
  });

  test('fails with a hint when opkg-build is absent', () async {
    Future<RunResult> noOpkg(
      String exe,
      List<String> args, {
      String? workingDirectory,
      Map<String, String>? environment,
      bool includeParentEnvironment = true,
      bool runInShell = false,
      ProcessOutputMode output = ProcessOutputMode.capture,
      String? label,
    }) async {
      if (exe == 'command') return const RunResult(1, '', ''); // not found
      return const RunResult(0, '', '');
    }

    final packager = IpkPackager(runProcess: noOpkg);
    expect(
      () => packager.build(
        binary: fakeBinary(),
        installPath: '/usr/bin/homescreen',
        meta: const IpkMetadata(
          name: 'app',
          version: '1',
          architecture: 'aarch64',
          maintainer: 'm <m@x>',
          description: 'd',
        ),
        outDir: Directory(p.join(tmp.path, 'dist')),
      ),
      throwsA(
        isA<IpkPackageException>().having(
          (e) => e.message,
          'message',
          contains('opkg-utils'),
        ),
      ),
    );
  });
}
