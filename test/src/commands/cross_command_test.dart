import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:emb_cli/src/commands/cross_command.dart';
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
  setUp(() => tmp = Directory.systemTemp.createTempSync('emb_xcmd_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  Future<int?> run(List<String> args) {
    final runner = CommandRunner<int>('emb', 'test')
      ..addCommand(CrossCommand(logger: Logger(), host: _host));
    return runner.run(args);
  }

  Directory pkgWith(String name, String embYaml) {
    final pkg = Directory(p.join(tmp.path, name))..createSync();
    File(p.join(pkg.path, 'emb.yaml')).writeAsStringSync(embYaml);
    return pkg;
  }

  test('usage error with no package argument', () async {
    expect(await run(['cross']), ExitCode.usage.code);
  });

  test('usage error when the dir has no manifest', () async {
    expect(await run(['cross', tmp.path]), ExitCode.usage.code);
  });

  test('usage error when the manifest has no cross: block', () async {
    final pkg = pkgWith('a', 'id: a\ntype: app\n');
    expect(await run(['cross', pkg.path]), ExitCode.usage.code);
  });

  test('usage error on an unknown provider token (G-03)', () async {
    final pkg = pkgWith('b', 'id: b\ntype: app\ncross:\n  provider: nope\n');
    expect(await run(['cross', pkg.path]), ExitCode.usage.code);
  });
}
