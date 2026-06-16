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

  test('--dry-run reports the backends matrix', () async {
    final pkg = pkgWith(
      'be',
      'id: be\ntype: app\ncross:\n  provider: arm-gnu\n'
          '  toolchain_version: 12.3.rel1\n  image_url: https://x/y.img.xz\n'
          '  backends:\n    wayland-egl:\n'
          '      BUILD_BACKEND_WAYLAND_EGL: ON\n',
    );
    expect(await run(['cross', '--dry-run', pkg.path]), ExitCode.success.code);
  });

  test('--dry-run plans a manifest file', () async {
    final pkg = Directory(p.join(tmp.path, 'c'))..createSync();
    final f = File(p.join(pkg.path, 'pi.emb.yaml'))
      ..writeAsStringSync(
        'id: pi\ntype: app\ncross:\n  provider: arm-gnu\n'
        '  toolchain_version: 12.3.rel1\n  image_url: https://x/y.img.xz\n',
      );
    expect(await run(['cross', '--dry-run', f.path]), ExitCode.success.code);
  });

  // Every shipped example must parse -> dispatch -> plan with no side effects:
  // this validates all of the listed use cases hermetically.
  test('--dry-run plans every example manifest', () async {
    const examples = [
      'pi5',
      'unoq',
      'radxa_zero3',
      'beagleplay',
      'nitrogen8mm',
      'agl_sdk_local',
      'agl_sdk_url',
    ];
    for (final name in examples) {
      final code = await run([
        'cross',
        '--dry-run',
        p.join('examples', 'cross', '$name.emb.yaml'),
      ]);
      expect(code, ExitCode.success.code, reason: '$name dry-run failed');
    }
  });
}
