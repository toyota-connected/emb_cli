import 'dart:io';

import 'package:emb_cli/src/cross/cross_profile.dart';
import 'package:emb_cli/src/cross/cross_target.dart';
import 'package:emb_cli/src/cross/yocto_recipe_cross_provider.dart';
import 'package:emb_cli/src/host/host_info.dart';
import 'package:emb_cli/src/workspace/workspace.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

const _host = HostInfo(
  os: HostOs.linux,
  machineArch: 'x86_64',
  archAliases: {'x86_64', 'x64', 'amd64'},
  hostType: 'fedora',
  versionId: '43',
);

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('emb_recipe_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  /// Stage `<build>/tmp/work/<tuple>/weston/<version>/recipe-sysroot{,-native}`
  /// with an executable gcc stub (prints [gccVersion] for `-dumpfullversion`)
  /// + EGL header so the provider locates, validates, and version-probes it.
  Directory fixtureBuild({
    bool gcc = true,
    bool egl = true,
    String version = '1.0',
    String gccVersion = '12.3.0',
  }) {
    const tuple = 'armv8a-mx8mm-poky-linux';
    const triple = 'aarch64-poky-linux';
    final ver = Directory(
      p.join(tmp.path, 'build', 'tmp', 'work', tuple, 'weston', version),
    )..createSync(recursive: true);
    if (egl) {
      File(p.join(ver.path, 'recipe-sysroot', 'usr', 'include', 'EGL', 'egl.h'))
        ..createSync(recursive: true)
        ..writeAsStringSync('');
    }
    if (gcc) {
      final exe =
          File(
              p.join(
                ver.path,
                'recipe-sysroot-native',
                'usr',
                'bin',
                triple,
                '$triple-gcc',
              ),
            )
            ..createSync(recursive: true)
            ..writeAsStringSync('#!/bin/sh\necho $gccVersion\n');
      Process.runSync('chmod', ['+x', exe.path]);
    }
    return Directory(p.join(tmp.path, 'build'));
  }

  CrossTarget makeTarget(String buildDir) => CrossTarget.fromMap({
    'provider': 'yocto-recipe',
    'yocto_build': buildDir,
    'machine_tuple': 'armv8a-mx8mm-poky-linux',
  });

  test('resolves a located recipe-sysroot into a profile', () async {
    final build = fixtureBuild();
    final r = await YoctoRecipeCrossProvider(
      makeTarget(build.path),
      workspace: Workspace(tmp),
      host: _host,
    ).resolve();

    expect(r.ok, isTrue, reason: r.message);
    final pf = r.profile!;
    expect(pf.targetTriple, 'aarch64-poky-linux');
    expect(pf.targetSysroot, endsWith('recipe-sysroot'));
    expect(pf.nativeSysroot, endsWith('recipe-sysroot-native'));
    expect(pf.cmakeToolchainFile, isNotNull);
    expect(pf.mesonCrossFile, isNotNull);
    expect(pf.cFlags, contains('-march=armv8-a+crc+crypto'));
  });

  test('captures a lock entry pinning the located recipe version', () async {
    final build = fixtureBuild();
    final r = await YoctoRecipeCrossProvider(
      makeTarget(build.path),
      workspace: Workspace(tmp),
      host: _host,
    ).resolve();

    expect(r.ok, isTrue, reason: r.message);
    final lock = r.lockEntry!;
    expect(lock.provider, 'yocto-recipe');
    expect(lock.triple, 'aarch64-poky-linux');
    // The newest recipe workdir version — drifts if the OE tree is rebuilt.
    expect(lock.toolchainVersion, '1.0');
    // The native gcc version, probed via -dumpfullversion (the stub).
    expect(lock.compilerVersion, '12.3.0');
    expect(lock.sysrootKey, isNotEmpty);
    expect(lock.buildKey, isNotEmpty);
    // Nothing is fetched, so there is no artifact to sha.
    expect(lock.artifacts, isEmpty);
  });

  test('picks the numerically-newest recipe version (10.0 over 9.0)', () async {
    fixtureBuild(version: '9.0');
    final build = fixtureBuild(version: '10.0');
    final r = await YoctoRecipeCrossProvider(
      makeTarget(build.path),
      workspace: Workspace(tmp),
      host: _host,
    ).resolve();

    expect(r.ok, isTrue, reason: r.message);
    // A lexical sort would pick "9.0"; the version-aware sort picks 10.0.
    expect(r.lockEntry!.toolchainVersion, '10.0');
  });

  test('unavailable without yocto_build / machine_tuple', () async {
    final r = await YoctoRecipeCrossProvider(
      CrossTarget.fromMap({'provider': 'yocto-recipe'}),
      workspace: Workspace(tmp),
      host: _host,
    ).resolve();
    expect(r.status, CrossResolveStatus.unavailable);
  });

  test('unavailable when the recipe is not built', () async {
    final r = await YoctoRecipeCrossProvider(
      makeTarget(p.join(tmp.path, 'empty')),
      workspace: Workspace(tmp),
      host: _host,
    ).resolve();
    expect(r.status, CrossResolveStatus.unavailable);
  });

  test('fails when the cross gcc is missing', () async {
    final build = fixtureBuild(gcc: false);
    final r = await YoctoRecipeCrossProvider(
      makeTarget(build.path),
      workspace: Workspace(tmp),
      host: _host,
    ).resolve();
    expect(r.status, CrossResolveStatus.failed);
  });
}
