import 'dart:io';

import 'package:emb_cli/src/cross/cross_profile.dart';
import 'package:emb_cli/src/cross/cross_target.dart';
import 'package:emb_cli/src/cross/yocto_sdk_cross_provider.dart';
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
  setUp(() => tmp = Directory.systemTemp.createTempSync('emb_sdk_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  /// Write a fake AGL `environment-setup-*` that exports the OE vars to temp
  /// paths (no real compiler) — `_sourceEnv` runs real `bash` against it.
  Directory fixtureSdk() {
    final sdk = Directory(p.join(tmp.path, 'agl-sdk'))..createSync();
    final tgt = '${tmp.path}/sysroots/aarch64-agl-linux';
    final nat = '${tmp.path}/sysroots/x86_64-aglsdk-linux';
    File(
      p.join(sdk.path, 'environment-setup-aarch64-agl-linux'),
    ).writeAsStringSync('''
export SDKTARGETSYSROOT="$tgt"
export OECORE_NATIVE_SYSROOT="$nat"
export OECORE_TARGET_ARCH="aarch64"
export OECORE_TARGET_OS="linux"
export OECORE_SDK_VERSION="4.0.10"
export CC="aarch64-agl-linux-gcc -mcpu=cortex-a57 --sysroot=\$SDKTARGETSYSROOT"
export CXX="aarch64-agl-linux-g++ -mcpu=cortex-a57 --sysroot=\$SDKTARGETSYSROOT"
export AR="aarch64-agl-linux-ar"
export STRIP="aarch64-agl-linux-strip"
export CFLAGS="-O2 -pipe -mcpu=cortex-a57"
export CXXFLAGS="-O2 -pipe -mcpu=cortex-a57"
export LDFLAGS="-Wl,-O1"
export PKG_CONFIG_SYSROOT_DIR="\$SDKTARGETSYSROOT"
export PKG_CONFIG_PATH="\$SDKTARGETSYSROOT/usr/lib/pkgconfig"
export CMAKE_TOOLCHAIN_FILE="\$OECORE_NATIVE_SYSROOT/usr/share/cmake/OEToolchainConfig.cmake"
''');
    return sdk;
  }

  test('sources a fake AGL SDK into a CrossProfile', () async {
    final sdk = fixtureSdk();
    final provider = YoctoSdkCrossProvider(
      CrossTarget.fromMap({
        'provider': 'yocto-sdk',
        'sdk_path': sdk.path,
        'triple': 'aarch64-agl-linux',
      }),
      workspace: Workspace(tmp),
      host: _host,
    );
    final r = await provider.resolve();
    provider.close();

    expect(r.ok, isTrue, reason: r.message);
    final pf = r.profile!;
    expect(pf.targetTriple, 'aarch64-agl-linux');
    expect(pf.cc, 'aarch64-agl-linux-gcc'); // bare binary split out of CC
    expect(pf.targetSysroot, endsWith('aarch64-agl-linux'));
    expect(pf.nativeSysroot, endsWith('x86_64-aglsdk-linux'));
    expect(pf.cFlags, contains('-mcpu=cortex-a57'));
    expect(pf.cmakeToolchainFile, endsWith('OEToolchainConfig.cmake'));
    // The full OE CC (with --sysroot) is preserved verbatim in the build env.
    expect(pf.buildEnv()['CC'], contains('--sysroot='));
    expect(pf.buildEnv()['SDKTARGETSYSROOT'], pf.targetSysroot);
  });

  test('captures a lock entry (sdk version, triple, keys)', () async {
    final sdk = fixtureSdk();
    final provider = YoctoSdkCrossProvider(
      CrossTarget.fromMap({
        'provider': 'yocto-sdk',
        'sdk_path': sdk.path,
        'triple': 'aarch64-agl-linux',
      }),
      workspace: Workspace(tmp),
      host: _host,
    );
    final r = await provider.resolve();
    provider.close();

    expect(r.ok, isTrue, reason: r.message);
    final lock = r.lockEntry!;
    expect(lock.provider, 'yocto-sdk');
    expect(lock.triple, 'aarch64-agl-linux');
    // Pinned from OECORE_SDK_VERSION — verifiable without any download.
    expect(lock.toolchainVersion, '4.0.10');
    expect(lock.sysrootKey, isNotEmpty);
    expect(lock.buildKey, isNotEmpty);
    // A local sdk_path install fetches nothing → no artifact to sha.
    expect(lock.artifacts, isEmpty);
  });

  test('resolves an explicit sdk_env_setup', () async {
    final sdk = fixtureSdk();
    final env = p.join(sdk.path, 'environment-setup-aarch64-agl-linux');
    final provider = YoctoSdkCrossProvider(
      CrossTarget.fromMap({
        'provider': 'yocto-sdk',
        'sdk_env_setup': env,
        'triple': 'aarch64-agl-linux',
      }),
      workspace: Workspace(tmp),
      host: _host,
    );
    final r = await provider.resolve();
    provider.close();
    expect(r.ok, isTrue, reason: r.message);
  });

  test('unavailable when no SDK location resolves', () async {
    final provider = YoctoSdkCrossProvider(
      CrossTarget.fromMap({
        'provider': 'yocto-sdk',
        'sdk_path': p.join(tmp.path, 'nope'),
      }),
      workspace: Workspace(tmp),
      host: _host,
    );
    final r = await provider.resolve();
    provider.close();
    expect(r.status, CrossResolveStatus.unavailable);
  });
}
