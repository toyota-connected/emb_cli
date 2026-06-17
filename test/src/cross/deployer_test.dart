import 'dart:io';

import 'package:emb_cli/src/cross/deployer.dart';
import 'package:test/test.dart';

({
  Future<ProcessResult> Function(
    String,
    List<String>, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool includeParentEnvironment,
    bool runInShell,
  })
  run,
  List<List<String>> calls,
})
recorder({
  bool Function(String exe)? failOn,
  bool Function(List<String> args)? exitNonZero,
}) {
  final calls = <List<String>>[];
  Future<ProcessResult> run(
    String exe,
    List<String> args, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool includeParentEnvironment = true,
    bool runInShell = false,
  }) async {
    calls.add([exe, ...args]);
    final fail =
        (failOn?.call(exe) ?? false) || (exitNonZero?.call(args) ?? false);
    return ProcessResult(0, fail ? 1 : 0, '', 'boom');
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
        host: 'pi@board',
        destDir: 'ivi-homescreen',
        port: 2222,
        opts: '-o StrictHostKeyChecking=no',
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
    ).push(tmp, host: 'pi@board', destDir: 'app');
    final rsync = rec.calls.firstWhere((c) => c.first == 'rsync');
    expect(rsync[rsync.indexOf('-e') + 1], 'ssh');
    expect(rsync.any((a) => a == '-p'), isFalse);
  });

  test('push reports failure when rsync fails', () async {
    final rec = recorder(failOn: (exe) => exe == 'rsync');
    final r = await Deployer(
      runProcess: rec.run,
    ).push(tmp, host: 'pi@board', destDir: 'app');
    expect(r.success, isFalse);
    expect(r.message, contains('rsync'));
  });

  test('falls back to tar-over-ssh when the target has no rsync', () async {
    // Probe (`command -v rsync`) returns non-zero → no remote rsync.
    final rec = recorder(exitNonZero: _isRsyncProbe);
    final r = await Deployer(
      runProcess: rec.run,
    ).push(tmp, host: 'pi@board', destDir: 'ivi-homescreen');
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
    Future<ProcessResult> run(
      String exe,
      List<String> args, {
      String? workingDirectory,
      Map<String, String>? environment,
      bool includeParentEnvironment = true,
      bool runInShell = false,
    }) async {
      calls.add([exe, ...args]);
      return ProcessResult(0, 0, 'aarch64\n', '');
    }

    final arch = await Deployer(
      runProcess: run,
    ).remoteArch('pi@board', port: 2222);
    expect(arch, 'aarch64');
    final ssh = calls.single;
    expect(ssh, containsAllInOrder(['ssh', '-p', '2222', 'pi@board']));
    expect(ssh.last, 'uname -m');
  });

  test('remoteArch returns null when the host is unreachable', () async {
    final rec = recorder(failOn: (exe) => exe == 'ssh');
    final arch = await Deployer(runProcess: rec.run).remoteArch('pi@board');
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
      'pi@board',
      'ivi-homescreen',
      './homescreen --b=.',
      port: 2222,
    );
    expect(argv, [
      'ssh',
      '-p',
      '2222',
      'pi@board',
      "cd 'ivi-homescreen' && ./homescreen --b=.",
    ]);
  });
}
