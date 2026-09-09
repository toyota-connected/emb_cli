import 'dart:async';
import 'dart:io';

import 'package:emb_cli/src/cross/cross_keys.dart';
import 'package:emb_cli/src/cross/cross_profile.dart';
import 'package:emb_cli/src/cross/cross_target.dart';
import 'package:emb_cli/src/cross/process_runner.dart';
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

  group('sdk_url download routing', () {
    // A stub Artifactory: the HTTP fallback's target. Every hit is counted, so
    // a test can assert jf was used *instead of* plain HTTP, not merely that
    // the download succeeded.
    late HttpServer server;
    var httpHits = 0;
    late String sdkUrl;

    setUp(() async {
      httpHits = 0;
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      unawaited(
        server.forEach((req) async {
          httpHits++;
          req.response.write('#!/bin/sh\n# fake installer\n');
          await req.response.close();
        }),
      );
      sdkUrl = 'http://127.0.0.1:${server.port}/artifactory/my-repo/agl-sdk.sh';
    });
    tearDown(() => server.close(force: true));

    /// `jf config show` output for a server whose authority is the stub's.
    /// PORT is substituted per test, since the stub binds an ephemeral port.
    const jfConfig =
        'Server ID:          prod-server\n'
        'Artifactory URL:    http://127.0.0.1:PORT/artifactory\n'
        'User:               ci-bot\n'
        'Default:            true\n';

    /// Where `_materializeFromUrl` stages the installer, and so where
    /// `_downloadViaJFrog` creates (and must remove) its `.jf-tmp-*` dir.
    Directory sdkDir(Directory root, CrossTarget t) => Directory(
      p.join(
        root.path,
        '.config',
        'flutter_workspace',
        'yocto-sdk-${sysrootKey(t)}',
      ),
    );

    CrossTarget urlTarget() => CrossTarget.fromMap({
      'provider': 'yocto-sdk',
      'sdk_url': sdkUrl,
      'triple': 'aarch64-agl-linux',
    });

    /// A fake [ProcessRunner] wired for the sdk_url path.
    ///
    /// [jfConfigShow] is what `jf config show` returns (throw a
    /// [ProcessException] to stand in for jf not being installed);
    /// [jfDownload] is what `jf rt dl` returns. `bash <installer>` materializes
    /// a real SDK prefix, so a download that succeeds resolves through to a
    /// profile and one that fails surfaces its own reason.
    ProcessRunner fakeRunner({
      required RunResult Function() jfConfigShow,
      RunResult Function(List<String> args)? jfDownload,
      List<String>? argvLog,
    }) {
      return (
        String exe,
        List<String> args, {
        String? workingDirectory,
        Map<String, String>? environment,
        bool includeParentEnvironment = true,
        bool runInShell = false,
        ProcessOutputMode output = ProcessOutputMode.capture,
        String? label,
      }) async {
        argvLog?.add('$exe ${args.join(' ')}');
        if (exe == 'jf') {
          if (args.first == 'config') return jfConfigShow();
          return jfDownload!(args);
        }
        if (exe == 'chmod') return const RunResult(0, '', '');
        if (exe == 'bash' && args.first != '-c') {
          // The installer: `bash <installer> -y -d <prefix>`.
          final prefix = Directory(args.last)..createSync(recursive: true);
          File(
            p.join(prefix.path, 'environment-setup-aarch64-agl-linux'),
          ).writeAsStringSync('');
          return const RunResult(0, '', '');
        }
        // `bash -c 'set -a; . $EMB_ENV_SETUP; printenv'`.
        return RunResult(0, '''
SDKTARGETSYSROOT=${tmp.path}/sysroots/aarch64-agl-linux
OECORE_NATIVE_SYSROOT=${tmp.path}/sysroots/x86_64-aglsdk-linux
OECORE_SDK_VERSION=13.0.3
CC=aarch64-agl-linux-gcc --sysroot=${tmp.path}/sysroots/aarch64-agl-linux
''', '');
      };
    }

    test('a matching server downloads via jf, never over HTTP', () async {
      final target = urlTarget();
      final argv = <String>[];
      final provider = YoctoSdkCrossProvider(
        target,
        workspace: Workspace(tmp),
        host: _host,
        runProcess: fakeRunner(
          argvLog: argv,
          jfConfigShow: () =>
              RunResult(0, jfConfig.replaceAll('PORT', '${server.port}'), ''),
          jfDownload: (args) {
            // `jf rt dl ... <repoPath> <tempDir>/` — stage the file under a
            // name that is deliberately *not* the URL basename, so listing what
            // landed (rather than deriving the name) is what makes this work.
            File(
              p.join(args.last, 'whatever-jf-called-it'),
            ).writeAsStringSync('#!/bin/sh\n');
            return const RunResult(0, '', '');
          },
        ),
      );
      final r = await provider.resolve();
      provider.close();

      expect(r.ok, isTrue, reason: r.message);
      expect(httpHits, 0, reason: 'jf handled it; HTTP must not be touched');
      expect(
        argv,
        contains(
          allOf(startsWith('jf rt dl'), contains('--server-id prod-server')),
        ),
      );
      // The staged file is renamed to the URL-derived installer name.
      expect(
        File(p.join(sdkDir(tmp, target).path, 'agl-sdk.sh')).existsSync(),
        isTrue,
      );
    });

    test('no server for the authority falls back to HTTP', () async {
      final provider = YoctoSdkCrossProvider(
        urlTarget(),
        workspace: Workspace(tmp),
        host: _host,
        runProcess: fakeRunner(
          // Configured, but for a different host.
          jfConfigShow: () => const RunResult(
            0,
            'Server ID:          other\n'
                'Artifactory URL:    https://elsewhere.example.com/artifactory\n',
            '',
          ),
        ),
      );
      final r = await provider.resolve();
      provider.close();

      expect(r.ok, isTrue, reason: r.message);
      expect(httpHits, 1);
    });

    test('jf config show non-zero falls back to HTTP', () async {
      final provider = YoctoSdkCrossProvider(
        urlTarget(),
        workspace: Workspace(tmp),
        host: _host,
        runProcess: fakeRunner(
          jfConfigShow: () => const RunResult(1, '', 'no config'),
        ),
      );
      final r = await provider.resolve();
      provider.close();

      expect(r.ok, isTrue, reason: r.message);
      expect(httpHits, 1);
    });

    test('jf absent falls back to HTTP', () async {
      final provider = YoctoSdkCrossProvider(
        urlTarget(),
        workspace: Workspace(tmp),
        host: _host,
        runProcess: fakeRunner(
          jfConfigShow: () => throw const ProcessException(
            'jf',
            ['config', 'show'],
            'not found',
            2,
          ),
        ),
      );
      final r = await provider.resolve();
      provider.close();

      expect(r.ok, isTrue, reason: r.message);
      expect(httpHits, 1);
    });

    test('jf rt dl failure reports the reason and does not retry over '
        'HTTP', () async {
      final provider = YoctoSdkCrossProvider(
        urlTarget(),
        workspace: Workspace(tmp),
        host: _host,
        runProcess: fakeRunner(
          jfConfigShow: () =>
              RunResult(0, jfConfig.replaceAll('PORT', '${server.port}'), ''),
          jfDownload: (_) => const RunResult(1, '', '404 Not Found'),
        ),
      );
      final r = await provider.resolve();
      provider.close();

      expect(r.status, CrossResolveStatus.unavailable);
      expect(r.message, contains('jf rt dl failed'));
      expect(r.message, contains('404 Not Found'));
      // A private Artifactory would 401 the anonymous retry; the jf error is
      // the useful one, so the fallback must not run and overwrite it.
      expect(httpHits, 0);
    });

    test('jf reporting success with nothing staged is a failure', () async {
      final provider = YoctoSdkCrossProvider(
        urlTarget(),
        workspace: Workspace(tmp),
        host: _host,
        runProcess: fakeRunner(
          jfConfigShow: () =>
              RunResult(0, jfConfig.replaceAll('PORT', '${server.port}'), ''),
          jfDownload: (_) => const RunResult(0, '', ''),
        ),
      );
      final r = await provider.resolve();
      provider.close();

      expect(r.status, CrossResolveStatus.unavailable);
      expect(r.message, contains('downloaded nothing'));
      expect(httpHits, 0);
    });

    test('the jf temp dir is removed on success and on failure', () async {
      final downloads = <String, RunResult Function(List<String>)>{
        'ok': (args) {
          File(p.join(args.last, 'agl-sdk.sh')).writeAsStringSync('x');
          return const RunResult(0, '', '');
        },
        'fail': (_) => const RunResult(1, '', 'boom'),
      };
      for (final entry in downloads.entries) {
        final target = urlTarget();
        final ws = Directory(p.join(tmp.path, 'ws-${entry.key}'))..createSync();
        final provider = YoctoSdkCrossProvider(
          target,
          workspace: Workspace(ws),
          host: _host,
          runProcess: fakeRunner(
            jfConfigShow: () =>
                RunResult(0, jfConfig.replaceAll('PORT', '${server.port}'), ''),
            jfDownload: entry.value,
          ),
        );
        await provider.resolve();
        provider.close();

        expect(
          sdkDir(
            ws,
            target,
          ).listSync().where((e) => p.basename(e.path).startsWith('.jf-tmp-')),
          isEmpty,
          reason: 'temp dir leaked on the ${entry.key} path',
        );
      }
    });

    test('offline denies the fetch before either egress path', () async {
      final argv = <String>[];
      final provider = YoctoSdkCrossProvider(
        urlTarget(),
        workspace: Workspace(tmp),
        host: _host,
        offline: true,
        runProcess: fakeRunner(
          argvLog: argv,
          jfConfigShow: () => fail('offline must not consult jf'),
        ),
      );
      final r = await provider.resolve();
      provider.close();

      expect(r.status, CrossResolveStatus.unavailable);
      expect(r.message, contains('offline'));
      expect(httpHits, 0);
      expect(argv, isEmpty);
    });
  });

  group('redactSecrets', () {
    test('masks a URL userinfo pair', () {
      expect(
        YoctoSdkCrossProvider.redactSecrets(
          'GET https://ci-bot:s3cr3t@artifacts.example.com/artifactory/x',
        ),
        'GET https://***@artifacts.example.com/artifactory/x',
      );
    });

    test('masks a bearer token', () {
      expect(
        YoctoSdkCrossProvider.redactSecrets('Authorization: Bearer abc.def'),
        'Authorization: ***',
      );
    });

    test('masks a keyed secret but keeps the field name', () {
      expect(
        YoctoSdkCrossProvider.redactSecrets('--access-token=abc123 --url=x'),
        '--access-token=*** --url=x',
      );
    });

    test('masks a bare JWT', () {
      expect(
        YoctoSdkCrossProvider.redactSecrets(
          'token eyJhbGciOiJSUzI1NiJ9.eyJzdWIiOiJ4In0.sig failed',
        ),
        'token *** failed',
      );
    });

    test('leaves an ordinary error untouched', () {
      const msg = '[Error] server response: 404 Not Found';
      expect(YoctoSdkCrossProvider.redactSecrets(msg), msg);
    });
  });
}
