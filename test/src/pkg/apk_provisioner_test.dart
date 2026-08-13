import 'dart:io';

import 'package:emb_cli/src/host/host_info.dart';
import 'package:emb_cli/src/pkg/_platform/apk_provisioner.dart';
import 'package:emb_cli/src/pkg/host_provisioner.dart';
import 'package:emb_cli/src/pkg/provision_models.dart';
import 'package:test/test.dart';

/// A fake `apk` that dispatches on the subcommand.
ApkRunner _fakeApk({
  int versionExit = 0,
  String info = '',
  String simulate = '',
  int simulateExit = 0,
  String addOut = '',
  String addErr = '',
  int addExit = 0,
  List<List<String>>? calls,
}) {
  return (args) async {
    calls?.add(args);
    if (args.first == '--version') return ProcessResult(0, versionExit, '', '');
    if (args.first == 'info') return ProcessResult(0, 0, info, '');
    if (args.contains('--simulate')) {
      return ProcessResult(0, simulateExit, simulate, '');
    }
    return ProcessResult(0, addExit, addOut, addErr); // apk add
  };
}

void main() {
  test('forHost selects apk on Alpine (no systemd needed)', () {
    const alpine = HostInfo(
      os: HostOs.linux,
      machineArch: 'x86_64',
      archAliases: {'x86_64'},
      hostType: 'alpine',
      versionId: '3.20',
    );
    expect(HostProvisioner.forHost(alpine), isA<ApkProvisioner>());
  });

  test('isAvailable reflects `apk --version`', () async {
    expect(await ApkProvisioner(run: _fakeApk()).isAvailable(), isTrue);
    expect(
      await ApkProvisioner(run: _fakeApk(versionExit: 1)).isAvailable(),
      isFalse,
    );
  });

  test('missing filters out already-installed packages', () async {
    final apk = ApkProvisioner(
      run: _fakeApk(info: 'musl\nbusybox\nwayland-libs-client\n'),
    );
    final missing = await apk.missing({'musl', 'wayland-dev', 'busybox'});
    expect(missing, {'wayland-dev'});
  });

  test('simulate parses would-install into toInstall + additional', () async {
    final apk = ApkProvisioner(
      // nothing installed → both packages would be installed.
      run: _fakeApk(
        simulate:
            '(1/2) Installing musl (1.2.5-r0)\n'
            '(2/2) Installing wayland-dev (1.23.0-r0)\n',
      ),
    );
    final plan = await apk.simulate({'wayland-dev'});
    expect(plan.toInstall, ['wayland-dev']);
    expect(plan.additional, ['musl']); // pulled in transitively
  });

  test('install succeeds and reports progress', () async {
    final labels = <String>[];
    final apk = ApkProvisioner(
      run: _fakeApk(addOut: '(1/1) Installing wayland-dev (1.23.0-r0)\n'),
    );
    final r = await apk.install({
      'wayland-dev',
    }, onProgress: (p) => labels.add(p.label));
    expect(r.success, isTrue);
    expect(r.installed, contains('wayland-dev'));
    expect(labels, contains('wayland-dev'));
  });

  test('install classifies an unresolved failure', () async {
    final apk = ApkProvisioner(
      run: _fakeApk(
        addExit: 1,
        addErr: 'ERROR: unable to select packages:\n  nope (no such package):',
      ),
    );
    final r = await apk.install({'nope'});
    expect(r.success, isFalse);
    expect(r.failed, ['nope']);
    expect(r.kind, ProvisionFailure.unresolved);
  });
}
