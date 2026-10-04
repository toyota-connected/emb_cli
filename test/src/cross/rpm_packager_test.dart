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
  final capturedScriptlets = <String, String>{};
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
      // The packager deletes _topdir once the build returns, so read the
      // scriptlet files it referenced while they still exist.
      for (final f in Directory(p.dirname(spec)).listSync().whereType<File>()) {
        final name = p.basename(f.path);
        if (name.startsWith('scriptlet-')) {
          capturedScriptlets[name] = f.readAsStringSync();
        }
      }
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
    // postinst → `%post -f <file>`; the body is NOT inlined, because rpmbuild
    // macro-expands a spec and that made the script's own text executable at
    // package time. The scriptlet file carries it instead.
    expect(capturedSpec, contains('%post -f '));
    expect(
      capturedSpec,
      isNot(contains('/sbin/ldconfig')),
      reason: 'the body must not be inlined into the spec',
    );
    expect(capturedScriptlets, contains('scriptlet-postinst'));
    expect(
      capturedScriptlets['scriptlet-postinst'],
      contains('/sbin/ldconfig'),
    );
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
  test('a scriptlet cannot reach the build host or the spec', () async {
    // rpmbuild macro-expands the spec, scriptlet bodies included: `%(cmd)` in a
    // maintainer script ran `cmd` on the *build host* at package time, and a
    // line starting with `%` closed the scriptlet and injected spec directives.
    // Verified against real rpmbuild: `-f` keeps such a line inert in the body,
    // and `%%` survives expansion as a single `%`, so the installed script is
    // unchanged while neither trick fires.
    final postinst = File(p.join(tmp.path, 'postinst'))
      ..writeAsStringSync(
        '#!/bin/sh\n'
        'echo "pct: 100%"\n'
        '%(touch /tmp/emb-rpm-build-host-rce)\n'
        '%files\n'
        '/etc/shadow\n',
      );
    final packager = RpmPackager(runProcess: fakeRun);
    await packager.build(
      binary: fakeBinary(),
      installPath: '/usr/bin/homescreen',
      meta: RpmMetadata(
        name: 'ivi-homescreen',
        version: '1.0.0',
        architecture: 'aarch64',
        license: 'MIT',
        summary: 'IVI shell',
        scriptlets: {'postinst': postinst.path},
      ),
      outDir: Directory(p.join(tmp.path, 'dist')),
    );

    // Nothing of the script's text reaches the spec.
    expect(capturedSpec, contains('%post -f '));
    expect(capturedSpec, isNot(contains('touch /tmp/emb-rpm-build-host-rce')));
    expect(capturedSpec, isNot(contains('/etc/shadow')));

    // Every `%` in the staged file is escaped, so rpm expands none of them.
    final staged = capturedScriptlets['scriptlet-postinst']!;
    expect(staged, contains('%%(touch /tmp/emb-rpm-build-host-rce)'));
    expect(staged, contains('%%files'));
    expect(staged, contains('echo "pct: 100%%"'));
    expect(
      RegExp('(?<!%)%(?!%)').hasMatch(staged),
      isFalse,
      reason: 'an unescaped % would be expanded by rpmbuild',
    );
  });
}
