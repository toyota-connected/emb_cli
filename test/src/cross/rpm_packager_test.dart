import 'dart:io';

import 'package:emb_cli/src/cross/process_runner.dart';
import 'package:emb_cli/src/cross/rpm_packager.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('emb_rpm_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  // A fake ProcessRunner standing in for command/chmod/rpmbuild, capturing the
  // generated .spec and faking the built rpm into RPMS/<arch>/.
  String? capturedSpec;
  List<String>? rpmbuildArgv;
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
    if (exe == 'command') return const RunResult(0, '/usr/bin/rpmbuild\n', '');
    if (exe == 'chmod') return const RunResult(0, '', '');
    if (exe == 'rpmbuild') {
      rpmbuildArgv = args;
      final spec = args.last;
      capturedSpec = File(spec).readAsStringSync();
      // Emulate the artifact rpmbuild would drop under _topdir/RPMS/<arch>/.
      final topDir = p.dirname(spec);
      File(
          p.join(
            topDir,
            'RPMS',
            'aarch64',
            'ivi-homescreen-1.0.0-1.aarch64.rpm',
          ),
        )
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('rpm');
      return const RunResult(0, '', '');
    }
    return const RunResult(0, '', '');
  }

  File fakeBinary() =>
      File(p.join(tmp.path, 'homescreen'))
        ..writeAsBytesSync([0x7f, 0x45, 0x4c, 0x46, 0, 0, 0, 0]);

  test('builds an .rpm and emits a valid spec', () async {
    final postinst = File(p.join(tmp.path, 'postinst'))
      ..writeAsStringSync('#!/bin/sh\n/sbin/ldconfig\n');
    final cfg = File(p.join(tmp.path, 'app.toml'))..writeAsStringSync('x');
    final packager = RpmPackager(runProcess: fakeRun);
    final out = await packager.build(
      binary: fakeBinary(),
      installPath: '/usr/bin/homescreen',
      meta: RpmMetadata(
        name: 'ivi-homescreen',
        version: '1.0.0',
        architecture: 'aarch64',
        license: 'MIT',
        summary: 'IVI shell',
        requires: const ['mesa-libgbm'],
        scriptlets: {'postinst': postinst.path},
      ),
      outDir: Directory(p.join(tmp.path, 'dist')),
      extraFiles: {cfg.path: '/etc/ivi/app.toml'},
    );

    expect(out.path, endsWith('ivi-homescreen-1.0.0-1.aarch64.rpm'));
    expect(capturedSpec, contains('Name: ivi-homescreen'));
    expect(capturedSpec, contains('License: MIT'));
    expect(capturedSpec, contains('BuildArch: aarch64'));
    expect(capturedSpec, contains('Requires: mesa-libgbm'));
    // postinst → %post scriptlet, with the script body inlined.
    expect(capturedSpec, contains('%post'));
    expect(capturedSpec, contains('/sbin/ldconfig'));
    // %install copies the staged payload; %files lists binary + extra file.
    expect(capturedSpec, contains('%install'));
    expect(capturedSpec, contains('cp -a'));
    expect(capturedSpec, contains('/usr/bin/homescreen'));
    expect(capturedSpec, contains('/etc/ivi/app.toml'));
    // Binary-mangling post-steps are disabled for the foreign-arch payload.
    expect(capturedSpec, contains('%global __os_install_post %{nil}'));
    // rpmbuild is invoked rootless with a private _topdir + --target.
    expect(rpmbuildArgv, contains('-bb'));
    expect(rpmbuildArgv!.any((a) => a.startsWith('_topdir ')), isTrue);
    expect(rpmbuildArgv, containsAllInOrder(['--target', 'aarch64']));
  });

  test('rejects a missing license', () async {
    final packager = RpmPackager(runProcess: fakeRun);
    expect(
      () => packager.build(
        binary: fakeBinary(),
        installPath: '/usr/bin/homescreen',
        meta: const RpmMetadata(
          name: 'app',
          version: '1',
          architecture: 'aarch64',
          license: '',
          summary: 's',
        ),
        outDir: Directory(p.join(tmp.path, 'dist')),
      ),
      throwsA(isA<RpmPackageException>()),
    );
  });

  test('fails with a hint when rpmbuild is absent', () async {
    Future<RunResult> noRpm(
      String exe,
      List<String> args, {
      String? workingDirectory,
      Map<String, String>? environment,
      bool includeParentEnvironment = true,
      bool runInShell = false,
      ProcessOutputMode output = ProcessOutputMode.capture,
      String? label,
    }) async {
      if (exe == 'command') return const RunResult(1, '', '');
      return const RunResult(0, '', '');
    }

    final packager = RpmPackager(runProcess: noRpm);
    expect(
      () => packager.build(
        binary: fakeBinary(),
        installPath: '/usr/bin/homescreen',
        meta: const RpmMetadata(
          name: 'app',
          version: '1',
          architecture: 'aarch64',
          license: 'MIT',
          summary: 's',
        ),
        outDir: Directory(p.join(tmp.path, 'dist')),
      ),
      throwsA(
        isA<RpmPackageException>().having(
          (e) => e.message,
          'message',
          contains('rpm-build'),
        ),
      ),
    );
  });
}
