import 'dart:io';

import 'package:emb_cli/src/cross/arm_gnu_cross_provider.dart';
import 'package:emb_cli/src/cross/cross_keys.dart';
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
  /// [resolve] short-circuits every download / mount / chroot step. The dir is
  /// keyed by the target's sysroot inputs, matching the provider.
  void prestage(
    String version,
    CrossTarget target, {
    String codename = 'bookworm',
  }) {
    final platform = Directory(
      p.join(
        tmp.path,
        '.config',
        'flutter_workspace',
        'cross-$_triple-${sysrootKey(target)}',
      ),
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
    final t = CrossTarget.fromMap({
      'provider': 'arm-gnu',
      'toolchain_version': '12.3.rel1',
      'image_url': 'https://example/x.img.xz',
      'cpu_flags': ['-mcpu=cortex-a76'],
    });
    prestage('12.3.rel1', t);
    final r = await resolveTarget(t);
    expect(r.ok, isTrue, reason: r.message);
    final pf = r.profile!;
    expect(pf.cc, endsWith('$_triple-gcc'));
    expect(pf.targetSysroot, endsWith('sysroot'));
    expect(pf.cFlags, contains('-mcpu=cortex-a76'));
    // Debian multiarch search path for crt*.o (-B) and libs (-L).
    expect(
      pf.cFlags.any(
        (f) => f.startsWith('-B') && f.contains('aarch64-linux-gnu'),
      ),
      isTrue,
    );
    expect(pf.cmakeToolchainFile, isNotNull);
  });

  test('derive: reads the sysroot codename to pick the version', () async {
    // bookworm -> 12.3.rel1; pre-stage that toolchain.
    final t = CrossTarget.fromMap({
      'provider': 'arm-gnu',
      'version_policy': 'derive',
      'cpu_flags': ['-mcpu=cortex-a53'],
      'sysroot': {'source': 'device', 'host': 'ubuntu@board'},
    });
    prestage('12.3.rel1', t);
    final r = await resolveTarget(t);
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

  // Bug #4: an absolute multiarch symlink must be rebased *within the sysroot*,
  // not relativized from the host filesystem root.
  test('relativizeSysrootSymlinks rebases absolute links into the sysroot', () {
    const ma = 'aarch64-linux-gnu';
    final sysroot = Directory(p.join(tmp.path, 'sysroot'));
    final libdir = Directory(p.join(sysroot.path, 'usr', 'lib', ma))
      ..createSync(recursive: true);
    final realLib = File(p.join(sysroot.path, 'lib', ma, 'libc.so.6'))
      ..createSync(recursive: true)
      ..writeAsStringSync('');
    // The kind of absolute symlink a Debian rootfs ships.
    Link(p.join(libdir.path, 'libc.so')).createSync('/lib/$ma/libc.so.6');

    relativizeSysrootSymlinks(sysroot, libdir);

    final tgt = Link(p.join(libdir.path, 'libc.so')).targetSync();
    expect(p.isRelative(tgt), isTrue, reason: 'should be relative, got $tgt');
    // It must resolve to the real lib inside the sysroot (not escape to host).
    final resolved = p.normalize(p.join(libdir.path, tgt));
    expect(resolved, realLib.path);
    expect(File(resolved).existsSync(), isTrue);
  });
}
