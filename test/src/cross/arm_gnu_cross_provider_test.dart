import 'dart:io';

import 'package:emb_cli/src/cross/arm_gnu_cross_provider.dart';
import 'package:emb_cli/src/cross/cross_profile.dart';
import 'package:emb_cli/src/cross/cross_target.dart';
import 'package:emb_cli/src/host/host_info.dart';
import 'package:emb_cli/src/workspace/workspace.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

const _linux = HostInfo(
  os: HostOs.linux,
  machineArch: 'x86_64',
  archAliases: {'x86_64', 'x64', 'amd64'},
  hostType: 'fedora',
  versionId: '43',
);

const _triple = 'aarch64-none-linux-gnu';

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('emb_armgnu_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  /// Pre-stage the sysroot (with [codename]) and an extracted toolchain so
  /// [resolve] short-circuits every download / mount / chroot step.
  void prestage(String version, {String codename = 'bookworm'}) {
    final platform = Directory(
      p.join(tmp.path, '.config', 'flutter_workspace', 'cross-$_triple'),
    );
    File(p.join(platform.path, 'sysroot', 'etc', 'os-release'))
      ..createSync(recursive: true)
      ..writeAsStringSync('VERSION_CODENAME=$codename\n');
    final dirName = 'arm-gnu-toolchain-$version-x86_64-$_triple';
    File(p.join(platform.path, 'toolchain', dirName, 'bin', '$_triple-gcc'))
      ..createSync(recursive: true)
      ..writeAsStringSync('');
  }

  Future<CrossResolveResult> resolveTarget(
    CrossTarget t, {
    HostInfo? host,
  }) async {
    final provider = ArmGnuCrossProvider(
      t,
      workspace: Workspace(tmp),
      host: host ?? _linux,
    );
    final r = await provider.resolve();
    provider.close();
    return r;
  }

  test('pinned: resolves a pre-staged toolchain + sysroot', () async {
    prestage('12.3.rel1');
    final r = await resolveTarget(
      CrossTarget.fromMap({
        'provider': 'arm-gnu',
        'toolchain_version': '12.3.rel1',
        'image_url': 'https://example/x.img.xz',
        'cpu_flags': ['-mcpu=cortex-a76'],
      }),
    );
    expect(r.ok, isTrue, reason: r.message);
    final pf = r.profile!;
    expect(pf.cc, endsWith('$_triple-gcc'));
    expect(pf.targetSysroot, endsWith('sysroot'));
    expect(pf.cFlags, ['-mcpu=cortex-a76']);
    expect(pf.cmakeToolchainFile, isNotNull);
  });

  test('derive: reads the sysroot codename to pick the version', () async {
    // bookworm -> 12.3.rel1; pre-stage that toolchain.
    prestage('12.3.rel1');
    final r = await resolveTarget(
      CrossTarget.fromMap({
        'provider': 'arm-gnu',
        'version_policy': 'derive',
        'cpu_flags': ['-mcpu=cortex-a53'],
        'sysroot': {'source': 'device', 'host': 'ubuntu@board'},
      }),
    );
    expect(r.ok, isTrue, reason: r.message);
    expect(r.profile!.cc, endsWith('$_triple-gcc'));
  });

  test('unavailable on a non-Linux host', () async {
    const mac = HostInfo(
      os: HostOs.macos,
      machineArch: 'arm64',
      archAliases: {'arm64'},
      hostType: 'macos',
      versionId: '14',
    );
    final r = await resolveTarget(
      CrossTarget.fromMap({'provider': 'arm-gnu'}),
      host: mac,
    );
    expect(r.status, CrossResolveStatus.unavailable);
  });

  test('unavailable when no toolchain version can be determined', () async {
    final r = await resolveTarget(
      CrossTarget.fromMap({
        'provider': 'arm-gnu',
        'image_url': 'https://example/x.img.xz',
      }),
    );
    expect(r.status, CrossResolveStatus.unavailable);
  });
}
