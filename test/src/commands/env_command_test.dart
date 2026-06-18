import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:emb_cli/src/commands/env_command.dart';
import 'package:emb_cli/src/host/host_info.dart';
import 'package:mason_logger/mason_logger.dart';
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
  setUp(() => tmp = Directory.systemTemp.createTempSync('emb_envcmd_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  Future<int?> run(List<String> args) {
    final runner = CommandRunner<int>('emb', 'test')
      ..addCommand(EnvCommand(logger: Logger(), host: _host));
    return runner.run(args);
  }

  test('writes setup_env.sh with FLUTTER_WORKSPACE from -w', () async {
    final ws = p.join(tmp.path, 'ws1');
    final code = await run(['env', '-w', ws]);
    expect(code, ExitCode.success.code);

    final text = File(p.join(ws, 'setup_env.sh')).readAsStringSync();
    expect(text, contains('export FLUTTER_WORKSPACE="$ws"'));
  });

  test('succeeds (warns, does not fail) when the SDK is absent', () async {
    // <workspace>/flutter does not exist — the command warns but still writes.
    final code = await run(['env', '-w', tmp.path]);
    expect(code, ExitCode.success.code);
    expect(File(p.join(tmp.path, 'setup_env.sh')).existsSync(), isTrue);
  });

  test('--print does not write a file', () async {
    final code = await run(['env', '-w', tmp.path, '--print']);
    expect(code, ExitCode.success.code);
    expect(File(p.join(tmp.path, 'setup_env.sh')).existsSync(), isFalse);
  });
}
