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
recorder({bool Function(String exe)? failOn}) {
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
    return ProcessResult(0, (failOn?.call(exe) ?? false) ? 1 : 0, '', 'boom');
  }

  return (run: run, calls: calls);
}

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

      final ssh = rec.calls.firstWhere((c) => c.first == 'ssh');
      expect(ssh, containsAllInOrder(['ssh', '-p', '2222']));
      expect(ssh, contains('pi@board'));
      expect(ssh.last, contains("mkdir -p 'ivi-homescreen'"));

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
