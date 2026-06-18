import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:emb_cli/src/commands/flutter_command.dart';
import 'package:emb_cli/src/flutter/flutter_sdk.dart';
import 'package:emb_cli/src/host/host_info.dart';
import 'package:emb_cli/src/repo/git_repo.dart';
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

/// Simulates a successful Flutter SDK install without touching git: creates the
/// SDK dir (and thus the workspace root) and reports an engine commit.
class _FakeSdk extends FlutterSdk {
  _FakeSdk(super.workspace);

  @override
  Future<FlutterInstallResult> install(
    String version, {
    GitRunner runner = defaultGitRunner,
  }) async {
    workspace.flutterDir.createSync(recursive: true);
    return FlutterInstallResult(
      success: true,
      path: workspace.flutterDir.path,
      engineCommit: 'deadbeefcafe',
    );
  }
}

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('emb_flcmd_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  Future<int?> run(List<String> args) {
    final runner = CommandRunner<int>('emb', 'test')
      ..addCommand(
        FlutterCommand(
          logger: Logger(),
          host: _host,
          sdkFactory: (ws, host) => _FakeSdk(ws),
        ),
      );
    return runner.run(args);
  }

  test('writes setup_env.sh with FLUTTER_WORKSPACE set to -w', () async {
    final ws = p.join(tmp.path, 'ws1');
    final code = await run([
      'flutter',
      '-w',
      ws,
      '--flutter-version',
      '3.44.2',
    ]);
    expect(code, ExitCode.success.code);

    final env = File(p.join(ws, 'setup_env.sh'));
    expect(env.existsSync(), isTrue);
    final text = env.readAsStringSync();
    // The -w target is the workspace, not the cwd a later bare `emb env` uses.
    expect(text, contains('export FLUTTER_WORKSPACE="$ws"'));
    // The engine commit read during install is carried into the env script.
    expect(text, contains('FLUTTER_ENGINE_VERSION="deadbeefcafe"'));
  });
}
