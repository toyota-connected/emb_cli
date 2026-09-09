import 'dart:io';

import 'package:emb_cli/src/cross/deployer.dart';
import 'package:emb_cli/src/cross/process_runner.dart';
import 'package:test/test.dart';

({ProcessRunner run, List<List<String>> calls}) recorder({
  bool Function(String exe)? failOn,
  bool Function(List<String> args)? exitNonZero,
}) {
  final calls = <List<String>>[];
  Future<RunResult> run(
    String exe,
    List<String> args, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool includeParentEnvironment = true,
    bool runInShell = false,
    ProcessOutputMode output = ProcessOutputMode.capture,
    String? label,
  }) async {
    calls.add([exe, ...args]);
    final fail =
        (failOn?.call(exe) ?? false) || (exitNonZero?.call(args) ?? false);
    return RunResult(fail ? 1 : 0, '', 'boom');
  }

  return (run: run, calls: calls);
}

/// A recorder whose remote `command -v rsync` probe says rsync is absent.
bool _isRsyncProbe(List<String> args) =>
    args.any((a) => a.contains('command -v rsync'));

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('emb_dep_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test(
    'push mkdirs the remote dir then rsyncs over the ssh transport',
    () async {
      final rec = recorder();
      final r = await Deployer(runProcess: rec.run).push(
        tmp,
        device: const DeployTarget.ssh(
          'pi@board',
          port: 2222,
          opts: '-o StrictHostKeyChecking=no',
        ),
        destDir: 'ivi-homescreen',
      );
      expect(r.success, isTrue);
      expect(r.method, 'rsync');

      // Probes for remote rsync, then mkdirs the remote dir.
      expect(
        rec.calls.any((c) => c.first == 'ssh' && _isRsyncProbe(c)),
        isTrue,
      );
      final mkdir = rec.calls.firstWhere(
        (c) => c.first == 'ssh' && c.last.contains('mkdir -p'),
      );
      expect(mkdir, containsAllInOrder(['ssh', '-p', '2222']));
      expect(mkdir, contains('pi@board'));
      expect(mkdir.last, contains("mkdir -p 'ivi-homescreen'"));

      final rsync = rec.calls.firstWhere((c) => c.first == 'rsync');
      expect(rsync, containsAllInOrder(['-az', '--delete']));
      final e = rsync[rsync.indexOf('-e') + 1];
      expect(e, 'ssh -p 2222 -o StrictHostKeyChecking=no');
      expect(rsync, contains('${tmp.path}/'));
      expect(rsync, contains('pi@board:ivi-homescreen/'));
    },
  );

  test('default port omits -p and uses a plain ssh transport', () async {
    final rec = recorder();
    await Deployer(
      runProcess: rec.run,
    ).push(tmp, device: const DeployTarget.ssh('pi@board'), destDir: 'app');
    final rsync = rec.calls.firstWhere((c) => c.first == 'rsync');
    expect(rsync[rsync.indexOf('-e') + 1], 'ssh');
    expect(rsync.any((a) => a == '-p'), isFalse);
  });

  test('push reports failure when rsync fails', () async {
    final rec = recorder(failOn: (exe) => exe == 'rsync');
    final r = await Deployer(
      runProcess: rec.run,
    ).push(tmp, device: const DeployTarget.ssh('pi@board'), destDir: 'app');
    expect(r.success, isFalse);
    expect(r.message, contains('rsync'));
  });

  test('falls back to tar-over-ssh when the target has no rsync', () async {
    // Probe (`command -v rsync`) returns non-zero → no remote rsync.
    final rec = recorder(exitNonZero: _isRsyncProbe);
    final r = await Deployer(runProcess: rec.run).push(
      tmp,
      device: const DeployTarget.ssh('pi@board'),
      destDir: 'ivi-homescreen',
    );
    expect(r.success, isTrue);
    expect(r.method, 'tar');
    // No rsync invocation; a single sh -c pipeline (tar | ssh … tar -x).
    expect(rec.calls.any((c) => c.first == 'rsync'), isFalse);
    final sh = rec.calls.firstWhere((c) => c.first == 'sh');
    expect(sh[1], '-c');
    expect(sh[2], startsWith('tar -czf - -C'));
    expect(sh[2], contains('| ssh pi@board'));
    expect(sh[2], contains('mkdir -p "ivi-homescreen"'));
    expect(sh[2], contains('tar -xzf - -C "ivi-homescreen"'));
  });

  test('remoteArch queries uname -m over the ssh transport', () async {
    final calls = <List<String>>[];
    Future<RunResult> run(
      String exe,
      List<String> args, {
      String? workingDirectory,
      Map<String, String>? environment,
      bool includeParentEnvironment = true,
      bool runInShell = false,
      ProcessOutputMode output = ProcessOutputMode.capture,
      String? label,
    }) async {
      calls.add([exe, ...args]);
      return const RunResult(0, 'aarch64\n', '');
    }

    final arch = await Deployer(
      runProcess: run,
    ).remoteArch(const DeployTarget.ssh('pi@board', port: 2222));
    expect(arch, 'aarch64');
    final ssh = calls.single;
    expect(ssh, containsAllInOrder(['ssh', '-p', '2222', 'pi@board']));
    expect(ssh.last, 'uname -m');
  });

  test('remoteArch returns null when the host is unreachable', () async {
    final rec = recorder(failOn: (exe) => exe == 'ssh');
    final arch = await Deployer(
      runProcess: rec.run,
    ).remoteArch(const DeployTarget.ssh('pi@board'));
    expect(arch, isNull);
  });

  test('archMatches tolerates arch aliases but rejects real mismatches', () {
    expect(archMatches('aarch64', 'aarch64'), isTrue);
    expect(archMatches('arm64', 'aarch64'), isTrue);
    expect(archMatches('x86_64', 'amd64'), isTrue);
    expect(archMatches('armv7hf', 'armv7l'), isTrue);
    expect(archMatches('x86_64', 'aarch64'), isFalse);
    expect(archMatches('aarch64', 'x86_64'), isFalse);
  });

  test('runArgv builds the remote run command', () {
    final argv = Deployer().runArgv(
      const DeployTarget.ssh('pi@board', port: 2222),
      'ivi-homescreen',
      './homescreen -b .',
    );
    expect(argv, [
      'ssh',
      '-p',
      '2222',
      'pi@board',
      "cd 'ivi-homescreen' && ./homescreen -b .",
    ]);
  });

  group('adb transport', () {
    test(
      'push mkdirs over adb shell then pushes the bundle contents',
      () async {
        final rec = recorder();
        final r = await Deployer(runProcess: rec.run).push(
          tmp,
          device: const DeployTarget.adb(serial: 'ABC123'),
          destDir: '/usr/share/ivi-homescreen',
        );
        expect(r.success, isTrue);
        expect(r.method, 'adb');
        // No ssh/rsync anywhere on this path.
        expect(
          rec.calls.any((c) => c.first == 'ssh' || c.first == 'rsync'),
          isFalse,
        );

        final mkdir = rec.calls.firstWhere((c) => c.contains('shell'));
        expect(mkdir, containsAllInOrder(['adb', '-s', 'ABC123', 'shell']));
        expect(mkdir.last, "mkdir -p '/usr/share/ivi-homescreen'");

        final push = rec.calls.firstWhere((c) => c.contains('push'));
        expect(push, containsAllInOrder(['adb', '-s', 'ABC123', 'push']));
        // `<dir>/.` pushes the contents; plain `<dir>` would nest the bundle.
        expect(push[push.indexOf('push') + 1], '${tmp.path}/.');
        expect(push.last, '/usr/share/ivi-homescreen');
      },
    );

    test('no serial omits -s, leaving adb its single-device default', () async {
      final rec = recorder();
      await Deployer(
        runProcess: rec.run,
      ).push(tmp, device: const DeployTarget.adb(), destDir: 'app');
      expect(rec.calls.every((c) => !c.contains('-s')), isTrue);
      expect(rec.calls.first.first, 'adb');
    });

    test('a failed push reports adb stdout when stderr is empty', () async {
      // adb writes most failures to stdout and still exits non-zero.
      Future<RunResult> run(
        String exe,
        List<String> args, {
        String? workingDirectory,
        Map<String, String>? environment,
        bool includeParentEnvironment = true,
        bool runInShell = false,
        ProcessOutputMode output = ProcessOutputMode.capture,
        String? label,
      }) async => args.contains('push')
          ? const RunResult(1, 'adb: error: failed to stat remote', '')
          : const RunResult(0, '', '');

      final r = await Deployer(
        runProcess: run,
      ).push(tmp, device: const DeployTarget.adb(), destDir: 'app');
      expect(r.success, isFalse);
      expect(r.message, contains('failed to stat remote'));
    });

    test('a missing adb binary is reported with a hint, not a crash', () async {
      Future<RunResult> run(
        String exe,
        List<String> args, {
        String? workingDirectory,
        Map<String, String>? environment,
        bool includeParentEnvironment = true,
        bool runInShell = false,
        ProcessOutputMode output = ProcessOutputMode.capture,
        String? label,
      }) async => throw const ProcessException('adb', [], 'No such file', 2);

      final r = await Deployer(
        runProcess: run,
      ).push(tmp, device: const DeployTarget.adb(), destDir: 'app');
      expect(r.success, isFalse);
      expect(r.message, contains('adb not found on PATH'));
    });

    test('remoteArch strips the CRLF adbd line-ends', () async {
      Future<RunResult> run(
        String exe,
        List<String> args, {
        String? workingDirectory,
        Map<String, String>? environment,
        bool includeParentEnvironment = true,
        bool runInShell = false,
        ProcessOutputMode output = ProcessOutputMode.capture,
        String? label,
      }) async => const RunResult(0, 'aarch64\r\n', '');

      final arch = await Deployer(
        runProcess: run,
      ).remoteArch(const DeployTarget.adb(serial: 'ABC123'));
      expect(arch, 'aarch64');
    });

    test('remoteArch returns null when adb is absent', () async {
      Future<RunResult> run(
        String exe,
        List<String> args, {
        String? workingDirectory,
        Map<String, String>? environment,
        bool includeParentEnvironment = true,
        bool runInShell = false,
        ProcessOutputMode output = ProcessOutputMode.capture,
        String? label,
      }) async => throw const ProcessException('adb', [], 'No such file', 2);

      final arch = await Deployer(
        runProcess: run,
      ).remoteArch(const DeployTarget.adb());
      expect(arch, isNull);
    });

    test('runArgv passes the whole command as one adb shell argument', () {
      final argv = Deployer().runArgv(
        const DeployTarget.adb(serial: 'ABC123'),
        'ivi-homescreen',
        './homescreen -b .',
      );
      expect(argv, [
        'adb',
        '-s',
        'ABC123',
        'shell',
        "cd 'ivi-homescreen' && ./homescreen -b .",
      ]);
    });
  });

  group('DeployTarget.parse', () {
    test('a bare host is ssh', () {
      final t = DeployTarget.parse('pi@board', port: 2222, opts: '-4');
      expect(t.transport, DeviceTransport.ssh);
      expect(t.host, 'pi@board');
      expect(t.port, 2222);
      expect(t.opts, '-4');
      expect(t.label, 'pi@board');
    });

    test('"adb" selects adb with no serial', () {
      final t = DeployTarget.parse('adb');
      expect(t.transport, DeviceTransport.adb);
      expect(t.serial, isNull);
      expect(t.label, 'adb');
    });

    test('"adb:<serial>" carries the serial', () {
      final t = DeployTarget.parse('adb:ABC123');
      expect(t.transport, DeviceTransport.adb);
      expect(t.serial, 'ABC123');
      expect(t.label, 'adb:ABC123');
    });

    test('"adb" falls back to the manifest serial', () {
      final t = DeployTarget.parse('adb', serial: 'FROM_MANIFEST');
      expect(t.serial, 'FROM_MANIFEST');
    });

    test('an explicit serial beats the manifest one', () {
      final t = DeployTarget.parse('adb:CLI', serial: 'FROM_MANIFEST');
      expect(t.serial, 'CLI');
    });

    test('a manifest adb transport makes a bare value a serial', () {
      // The Yocto/AGL shape: `transport: adb` in the manifest, `--deploy
      // ABC123` on the command line.
      final t = DeployTarget.parse('ABC123', transport: DeviceTransport.adb);
      expect(t.transport, DeviceTransport.adb);
      expect(t.serial, 'ABC123');
    });

    test('"adb" overrides an ssh manifest, so no device block is needed', () {
      final t = DeployTarget.parse('adb:X', port: 2222);
      expect(t.transport, DeviceTransport.adb);
      expect(t.host, isNull);
    });
  });
}
