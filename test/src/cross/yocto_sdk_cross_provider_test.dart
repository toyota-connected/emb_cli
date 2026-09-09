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

  group('parseArtifactoryPath', () {
    test('plain artifactory URL', () {
      final r = YoctoSdkCrossProvider.parseArtifactoryPath(
        'https://artifacts.example.com/artifactory/my-repo/path/to/sdk.sh',
      );
      expect(r, ('artifacts.example.com', 'my-repo/path/to/sdk.sh'));
    });

    test('api/download URL strips prefix', () {
      final r = YoctoSdkCrossProvider.parseArtifactoryPath(
        'https://artifacts.example.com/artifactory/api/download/my-repo/path/to/sdk.sh',
      );
      expect(r, ('artifacts.example.com', 'my-repo/path/to/sdk.sh'));
    });

    test('URL with port preserves authority', () {
      final r = YoctoSdkCrossProvider.parseArtifactoryPath(
        'https://artifacts.example.com:8081/artifactory/my-repo/sdk.sh',
      );
      expect(r, ('artifacts.example.com:8081', 'my-repo/sdk.sh'));
    });

    test('no /artifactory/ segment returns null', () {
      expect(
        YoctoSdkCrossProvider.parseArtifactoryPath(
          'https://example.com/releases/sdk.sh',
        ),
        isNull,
      );
    });

    test('relative URL (no authority) returns null', () {
      // Uri.tryParse('').authority is also '', so an empty authority would
      // match a server record that has no Artifactory URL field.
      expect(
        YoctoSdkCrossProvider.parseArtifactoryPath('artifactory/repo/sdk.sh'),
        isNull,
      );
    });

    test('percent-encoded basename decodes into the repo path', () {
      final r = YoctoSdkCrossProvider.parseArtifactoryPath(
        'https://artifacts.example.com/artifactory/my-repo/my%2Bsdk%201.sh',
      );
      // pathSegments decodes; the jf pattern must carry the real artifact name.
      expect(r, ('artifacts.example.com', 'my-repo/my+sdk 1.sh'));
    });

    test('/artifactory/ with no path after it returns null', () {
      expect(
        YoctoSdkCrossProvider.parseArtifactoryPath(
          'https://artifacts.example.com/artifactory/',
        ),
        isNull,
      );
    });
  });

  group('parseJFrogServers', () {
    // Realistic `jf config show` output with two configured servers.
    const multiServerOutput = '''
Server ID:          prod-server
Artifactory URL:    https://artifacts.example.com/artifactory
Access URL:         https://artifacts.example.com/access
User:               ci-bot
Password/API key:   ***
Default:            true

Server ID:          staging
Artifactory URL:    https://staging.example.com/artifactory
Access URL:         https://staging.example.com/access
User:               ci-bot
Password/API key:   ***
Default:            false
''';

    test('parses two servers', () {
      final servers = YoctoSdkCrossProvider.parseJFrogServers(
        multiServerOutput,
      );
      expect(servers, hasLength(2));
    });

    test('first server fields', () {
      final servers = YoctoSdkCrossProvider.parseJFrogServers(
        multiServerOutput,
      );
      expect(servers[0]['Server ID'], 'prod-server');
      expect(
        servers[0]['Artifactory URL'],
        'https://artifacts.example.com/artifactory',
      );
      expect(servers[0]['Default'], 'true');
    });

    test('second server fields', () {
      final servers = YoctoSdkCrossProvider.parseJFrogServers(
        multiServerOutput,
      );
      expect(servers[1]['Server ID'], 'staging');
      expect(
        servers[1]['Artifactory URL'],
        'https://staging.example.com/artifactory',
      );
      expect(servers[1]['Default'], 'false');
    });

    test('empty output returns empty list', () {
      expect(YoctoSdkCrossProvider.parseJFrogServers(''), isEmpty);
    });

    test('authority matching against Artifactory URL', () {
      final servers = YoctoSdkCrossProvider.parseJFrogServers(
        multiServerOutput,
      );
      final match = servers.firstWhere(
        (s) =>
            Uri.tryParse(s['Artifactory URL'] ?? '')?.authority ==
            'artifacts.example.com',
        orElse: () => {},
      );
      expect(match['Server ID'], 'prod-server');
    });
  });
}
