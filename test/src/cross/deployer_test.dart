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
    // Single-quoted, not double: the remote shell expands inside "…".
    expect(sh[2], contains(_shq(_remoteFor('ivi-homescreen'))));
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
      'push archives locally, transfers via adb push (no shell/PTY), extracts on device',
      () async {
        final rec = recorder();
        final r = await Deployer(runProcess: rec.run).push(
          tmp,
          device: const DeployTarget.adb(serial: 'ABC123'),
          destDir: '/usr/share/ivi-homescreen',
        );
        expect(r.success, isTrue);
        expect(r.method, 'adb');
        expect(
          rec.calls.any((c) => c.first == 'ssh' || c.first == 'rsync'),
          isFalse,
        );
        // Local tar created first.
        final tarCall = rec.calls.firstWhere((c) => c.first == 'tar');
        expect(tarCall, containsAllInOrder(['-cf']));
        expect(tarCall, contains('-C'));
        // adb push of the tar file includes serial.
        final pushCall = rec.calls.firstWhere(
          (c) => c.first == 'adb' && c.contains('push'),
        );
        expect(pushCall, containsAllInOrder(['adb', '-s', 'ABC123', 'push']));
        expect(pushCall.last, '/tmp/.emb-deploy.tar');
        // adb shell extracts into destDir.
        final extractCall = rec.calls.firstWhere(
          (c) =>
              c.first == 'adb' &&
              c.contains('shell') &&
              c.any((a) => a.startsWith('tar -xf')),
        );
        expect(
          extractCall,
          containsAllInOrder(['adb', '-s', 'ABC123', 'shell']),
        );
        expect(extractCall.last, contains(_shq('/usr/share/ivi-homescreen')));
        // adb shell rm cleans up the remote tar.
        expect(
          rec.calls.any(
            (c) =>
                c.first == 'adb' &&
                c.contains('shell') &&
                c.any((a) => a.startsWith('rm -f')),
          ),
          isTrue,
        );
      },
    );

    test('no serial omits -s, leaving adb its single-device default', () async {
      final rec = recorder();
      final r = await Deployer(
        runProcess: rec.run,
      ).push(tmp, device: const DeployTarget.adb(), destDir: 'app');
      expect(r.method, 'adb');
      expect(rec.calls.every((c) => !c.contains('-s')), isTrue);
    });

    test(
      'falls back to recursive push when tar is absent on the device',
      () async {
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
          // adb shell tar -xf returns 127: tar absent on device.
          if (exe == 'adb' &&
              args.contains('shell') &&
              args.any((a) => a.startsWith('tar '))) {
            return const RunResult(127, '', 'tar: not found');
          }
          return const RunResult(0, '', '');
        }

        final r = await Deployer(runProcess: run).push(
          tmp,
          device: const DeployTarget.adb(serial: 'X'),
          destDir: 'app',
        );
        expect(r.success, isTrue);
        expect(r.method, 'adb');
        // Local tar first.
        expect(calls.first.first, 'tar');
        // Two adb push calls: tar file, then fallback file push.
        final pushCalls = calls
            .where((c) => c.first == 'adb' && c.contains('push'))
            .toList();
        expect(pushCalls.length, 2);
        // rm cleanup ran.
        expect(
          calls.any(
            (c) => c.first == 'adb' && c.any((a) => a.startsWith('rm -f')),
          ),
          isTrue,
        );
        // No rm -rf.
        expect(calls.any((c) => c.any((a) => a.contains('rm -rf'))), isFalse);
      },
    );

    test(
      'a non-127 extract failure is reported without attempting fallback',
      () async {
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
          // adb shell tar -xf fails with a real error (not 127).
          if (exe == 'adb' &&
              args.contains('shell') &&
              args.any((a) => a.startsWith('tar '))) {
            return const RunResult(1, '', 'error');
          }
          return const RunResult(0, '', '');
        }

        final r = await Deployer(
          runProcess: run,
        ).push(tmp, device: const DeployTarget.adb(), destDir: 'app');
        expect(r.success, isFalse);
        expect(r.method, 'adb');
        expect(r.message, isNotEmpty);
        // rm still ran (cleanup on failure).
        expect(
          calls.any(
            (c) => c.first == 'adb' && c.any((a) => a.startsWith('rm -f')),
          ),
          isTrue,
        );
        // No fallback adb push of the full directory.
        expect(
          calls.any(
            (c) =>
                c.first == 'adb' &&
                c.contains('push') &&
                c.any((a) => a.endsWith('/.')),
          ),
          isFalse,
        );
      },
    );

    test(
      'a failed adb push fallback reports stdout when stderr is empty',
      () async {
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
        }) async {
          // tar absent on device → fallback.
          if (exe == 'adb' &&
              args.contains('shell') &&
              args.any((a) => a.startsWith('tar '))) {
            return const RunResult(127, '', 'tar: not found');
          }
          // Fallback adb push of individual files fails.
          if (exe == 'adb' &&
              args.contains('push') &&
              args.any((a) => a.endsWith('/.'))) {
            return const RunResult(1, 'adb: error: failed to stat remote', '');
          }
          return const RunResult(0, '', '');
        }

        final r = await Deployer(
          runProcess: run,
        ).push(tmp, device: const DeployTarget.adb(), destDir: 'app');
        expect(r.success, isFalse);
        expect(r.message, contains('failed to stat remote'));
      },
    );

    test('a missing tar binary is reported with a hint, not a crash', () async {
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
        if (exe == 'tar') {
          throw const ProcessException('tar', [], 'No such file', 2);
        }
        return const RunResult(0, '', '');
      }

      final r = await Deployer(
        runProcess: run,
      ).push(tmp, device: const DeployTarget.adb(), destDir: 'app');
      expect(r.success, isFalse);
      expect(r.method, 'adb');
      expect(r.message, contains('tar not found on PATH'));
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
      }) async {
        if (exe == 'tar') return const RunResult(0, '', '');
        throw const ProcessException('adb', [], 'No such file', 2);
      }

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
  test('a deploy dir cannot run a command on the board', () async {
    // `_pushTar` built the remote command with double quotes, so the board's
    // shell expanded it. `--deploy-dir` reaches here, and so does a
    // `cross.backends` key, which is concatenated into the destination.
    final rec = recorder(exitNonZero: _isRsyncProbe);
    const dest = 'ivi"; touch /tmp/emb-pwned; echo "';
    await Deployer(
      runProcess: rec.run,
    ).push(tmp, device: const DeployTarget.ssh('pi@board'), destDir: dest);
    final sh = rec.calls.firstWhere((c) => c.first == 'sh')[2];
    // Both layers must be right: the destination quoted for the *board's* shell
    // (inner), and that whole remote command quoted for the local `sh -c`
    // (outer). _shq here is an independent implementation, so dropping either
    // layer in the packager fails this.
    expect(sh, contains(_shq(_remoteFor(dest))));
    // Separately verified with a fake ssh that joins its args and runs them
    // through a shell: the board received `mkdir -p 'ivi"; touch …; echo "'`
    // as one argument and the canary file was never created.
  });
}

/// POSIX single-quoting, written out independently of the implementation.
String _shq(String s) => "'${s.replaceAll("'", r"'\''")}'";

/// The remote command `_pushTar` must build for [dest].
String _remoteFor(String dest) =>
    'mkdir -p ${_shq(dest)} && tar -xzf - -C ${_shq(dest)}';
