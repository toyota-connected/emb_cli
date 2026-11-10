import 'dart:io';

import 'package:emb_cli/src/exec/container_launcher.dart';
import 'package:emb_cli/src/exec/container_reentry.dart';
import 'package:emb_cli/src/host/host_info.dart';
import 'package:emb_cli/src/verbosity.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

HostInfo _host(HostOs os, String arch) => HostInfo(
  os: os,
  machineArch: arch,
  archAliases: const {},
  hostType: os.name,
  versionId: '1',
);

ContainerLauncher _fakeLauncher(void Function(String, List<String>) capture) =>
    ContainerLauncher(
      run: (exe, args, {environment}) async {
        capture(exe, args);
        return ProcessResult(0, 0, '', '');
      },
    );

void main() {
  test('linux x86_64 host runs native (null)', () async {
    var launched = false;
    final r = ContainerReentry(
      host: _host(HostOs.linux, 'x86_64'),
      launcher: _fakeLauncher((_, _) => launched = true),
      image: 'img',
    );
    final code = await r.maybeRun(embArgs: const ['aot'], mounts: const []);
    expect(code, isNull);
    expect(launched, isFalse);
  });

  test('macOS host routes and returns the inner exit code', () async {
    String? seenTool;
    List<String>? seenArgs;
    final r = ContainerReentry(
      host: _host(HostOs.macos, 'arm64'),
      launcher: ContainerLauncher(
        tool: 'podman',
        run: (exe, args, {environment}) async {
          seenTool = exe;
          seenArgs = args;
          return ProcessResult(0, 3, '', '');
        },
      ),
      image: 'ghcr.io/x/runtime:latest',
    );
    final code = await r.maybeRun(
      embArgs: const ['bundle', '--app-path', '/w/app'],
      mounts: const [Mount('/w')],
      workdir: '/w',
    );
    expect(code, 3);
    expect(seenTool, 'podman');
    expect(seenArgs, contains('ghcr.io/x/runtime:latest'));
    expect(seenArgs!.last, '--exec-native');
  });

  test('forceNative and inContainer short-circuit to native', () async {
    final mac = ContainerReentry(
      host: _host(HostOs.macos, 'arm64'),
      launcher: _fakeLauncher((_, _) {}),
      image: 'img',
    );
    expect(
      await mac.maybeRun(
        embArgs: const ['aot'],
        mounts: const [],
        forceNative: true,
      ),
      isNull,
    );

    final inContainer = ContainerReentry(
      host: _host(HostOs.macos, 'arm64'),
      launcher: _fakeLauncher((_, _) {}),
      image: 'img',
      inContainer: true,
    );
    expect(
      await inContainer.maybeRun(embArgs: const ['aot'], mounts: const []),
      isNull,
    );
  });

  group('containerAuthContext', () {
    late Verbosity savedVerbosity;

    setUp(() => savedVerbosity = embVerbosity);
    tearDown(() => embVerbosity = savedVerbosity);

    test('forwards GH_TOKEN as git config env vars', () {
      final auth = ContainerReentry.containerAuthContext(
        hostEnv: {'GH_TOKEN': 'ghp_secret123'},
        isMacOrWin: false,
      );
      expect(auth.env['GIT_CONFIG_COUNT'], '1');
      expect(
        auth.env['GIT_CONFIG_KEY_0'],
        'url.https://x-access-token:ghp_secret123@github.com/.insteadOf',
      );
      expect(auth.env['GIT_CONFIG_VALUE_0'], 'https://github.com/');
      expect(auth.mounts, isEmpty);
    });

    test('prefers GH_TOKEN over GITHUB_TOKEN', () {
      final auth = ContainerReentry.containerAuthContext(
        hostEnv: {'GH_TOKEN': 'preferred', 'GITHUB_TOKEN': 'fallback'},
        isMacOrWin: false,
      );
      expect(auth.env['GIT_CONFIG_KEY_0'], contains('preferred'));
    });

    test('falls back to GITHUB_TOKEN', () {
      final auth = ContainerReentry.containerAuthContext(
        hostEnv: {'GITHUB_TOKEN': 'fallback'},
        isMacOrWin: false,
      );
      expect(auth.env['GIT_CONFIG_KEY_0'], contains('fallback'));
    });

    test('omits git config when no token present', () {
      final auth = ContainerReentry.containerAuthContext(
        hostEnv: {},
        isMacOrWin: false,
      );
      expect(auth.env, isNot(contains('GIT_CONFIG_COUNT')));
    });

    test('on Linux, omits SSH when socket does not exist', () {
      final auth = ContainerReentry.containerAuthContext(
        hostEnv: {'SSH_AUTH_SOCK': '/tmp/no-such-socket-ever'},
        isMacOrWin: false,
      );
      expect(auth.env, isNot(contains('SSH_AUTH_SOCK')));
      expect(auth.mounts, isEmpty);
    });

    test('on Linux, includes SSH mount and env when socket exists', () {
      final tmp = File(
        '${Directory.systemTemp.path}/emb-test-ssh-sock-${DateTime.now().millisecondsSinceEpoch}',
      )..writeAsStringSync('');
      addTearDown(tmp.deleteSync);

      final auth = ContainerReentry.containerAuthContext(
        hostEnv: {'SSH_AUTH_SOCK': tmp.path},
        isMacOrWin: false,
      );
      expect(auth.env['SSH_AUTH_SOCK'], tmp.path);
      expect(auth.mounts, hasLength(1));
      expect(auth.mounts.first.path, tmp.path);
      expect(auth.mounts.first.containerPath, isNull);
    });

    test('on macOS, uses Docker Desktop magic socket path', () {
      final auth = ContainerReentry.containerAuthContext(
        hostEnv: {'SSH_AUTH_SOCK': '/some/mac/agent.sock'},
        isMacOrWin: true,
      );
      const magic = '/run/host-services/ssh-auth.sock';
      expect(auth.env['SSH_AUTH_SOCK'], magic);
      expect(auth.mounts, hasLength(1));
      expect(auth.mounts.first.path, magic);
      expect(auth.mounts.first.containerPath, magic);
    });

    test('on macOS, omits SSH when SSH_AUTH_SOCK unset', () {
      final auth = ContainerReentry.containerAuthContext(
        hostEnv: {},
        isMacOrWin: true,
      );
      expect(auth.env, isNot(contains('SSH_AUTH_SOCK')));
      expect(auth.mounts, isEmpty);
    });

    test('forwards verbosity when above normal', () {
      embVerbosity = Verbosity.verbose;
      final auth = ContainerReentry.containerAuthContext(
        hostEnv: {},
        isMacOrWin: false,
      );
      expect(auth.env['EMB_VERBOSITY'], '${Verbosity.verbose.index}');
    });

    test('omits verbosity at normal level', () {
      embVerbosity = Verbosity.normal;
      final auth = ContainerReentry.containerAuthContext(
        hostEnv: {},
        isMacOrWin: false,
      );
      expect(auth.env, isNot(contains('EMB_VERBOSITY')));
    });

    test('mounts ~/.netrc read-only and skips GIT_CONFIG env vars', () {
      final tmpHome = Directory.systemTemp.createTempSync('emb-test-home-');
      addTearDown(() => tmpHome.deleteSync(recursive: true));
      File('${tmpHome.path}/.netrc').writeAsStringSync(
        'machine github.com login x-access-token password ghp_test\n',
      );

      final auth = ContainerReentry.containerAuthContext(
        hostEnv: {'HOME': tmpHome.path, 'GH_TOKEN': 'ghp_ignored'},
        isMacOrWin: false,
      );
      // .netrc mounted read-only at /root/.netrc
      final netrcMount = auth.mounts.where(
        (m) => m.containerPath == '/root/.netrc',
      );
      expect(netrcMount, hasLength(1));
      expect(netrcMount.first.path, '${tmpHome.path}/.netrc');
      expect(netrcMount.first.readOnly, isTrue);
      // GIT_CONFIG env vars suppressed
      expect(auth.env, isNot(contains('GIT_CONFIG_COUNT')));
    });

    test('falls back to GIT_CONFIG env vars when no ~/.netrc', () {
      final tmpHome = Directory.systemTemp.createTempSync('emb-test-home-');
      addTearDown(() => tmpHome.deleteSync(recursive: true));
      // No .netrc created

      final auth = ContainerReentry.containerAuthContext(
        hostEnv: {'HOME': tmpHome.path, 'GH_TOKEN': 'ghp_used'},
        isMacOrWin: false,
      );
      expect(auth.env['GIT_CONFIG_COUNT'], '1');
      expect(auth.env['GIT_CONFIG_KEY_0'], contains('ghp_used'));
      expect(
        auth.mounts.where((m) => m.containerPath == '/root/.netrc'),
        isEmpty,
      );
    });
  });

  test('mountsFor keeps existing dirs, dedups, drops nulls/missing', () {
    final tmp = Directory.systemTemp.createTempSync('emb-reentry-mounts-');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final a = Directory(p.join(tmp.path, 'a'))..createSync();
    final missing = p.join(tmp.path, 'nope');
    final mounts = ContainerReentry.mountsFor([
      a.path,
      a.path, // dup
      missing, // does not exist
      null,
    ]);
    expect(mounts.map((m) => m.path), [a.absolute.path]);
  });
}
