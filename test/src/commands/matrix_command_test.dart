import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:emb_cli/src/commands/matrix_command.dart';
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

const _singleTarget = '''
id: ivi-homescreen
type: app
supported_archs: [arm64]
supported_host_types: [ubuntu, fedora]
cross:
  provider: arm-gnu
  triple: aarch64-none-linux-gnu
  toolchain_version: 12.3.rel1
  image_url: https://example.com/os.img.xz
  cpu_flags: [-mcpu=cortex-a76]
''';

const _multiTarget = '''
id: ivi-homescreen
type: app
supported_host_types: [ubuntu]
cross:
  provider: arm-gnu
  toolchain_version: 12.3.rel1
  targets:
    rpi5:
      image_url: https://example.com/raspios.img.xz
      cpu_flags: [-mcpu=cortex-a76]
    rpi4:
      image_url: https://example.com/raspios.img.xz
      cpu_flags: [-mcpu=cortex-a72]
''';

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('emb_matrix_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  Future<int?> run(List<String> args) {
    final runner = CommandRunner<int>('emb', 'test')
      ..addCommand(MatrixCommand(logger: Logger(), host: _host));
    return runner.run(args);
  }

  File write(String name, String yaml) =>
      File(p.join(tmp.path, name))..writeAsStringSync(yaml);

  /// Render to a file (robust capture) and return its `include` list.
  Future<List<Map<String, dynamic>>> render(List<String> args) async {
    final outFile = p.join(tmp.path, 'matrix.json');
    final code = await run(['matrix', ...args, '-o', outFile]);
    expect(code, ExitCode.success.code);
    final decoded = jsonDecode(File(outFile).readAsStringSync()) as Map;
    return (decoded['include'] as List).cast<Map<String, dynamic>>();
  }

  test('usage error with no path argument', () async {
    expect(await run(['matrix']), ExitCode.usage.code);
  });

  test('a single-target manifest fans out over its supported hosts', () async {
    final f = write('pi5.emb.yaml', _singleTarget);
    final include = await render([f.path]);

    expect(include, hasLength(2)); // ubuntu + fedora
    final ubuntu = include.firstWhere((e) => e['host'] == 'ubuntu');
    expect(ubuntu['provider'], 'arm-gnu');
    expect(ubuntu['triple'], 'aarch64-none-linux-gnu');
    expect(ubuntu['target'], 'default');
    expect(ubuntu['runs_on'], 'ubuntu-latest');
    expect(ubuntu['args'], f.path); // no --target for a flat cross block
    expect(ubuntu['preflight'], 'tar xz rsync'); // arm-gnu preflight tools
    expect(ubuntu['sysroot_key'], isNotEmpty);
    expect(ubuntu['build_key'], isNotEmpty);

    final fedora = include.firstWhere((e) => e['host'] == 'fedora');
    expect(fedora['runs_on'], 'ubuntu-latest');
    expect(fedora['container'], 'fedora:41'); // no hosted fedora runner
  });

  test(
    'cpu-only variants share a sysroot_key but differ on build_key',
    () async {
      final f = write('rpi.emb.yaml', _multiTarget);
      final include = await render([f.path]);

      expect(include, hasLength(2)); // rpi5, rpi4 (one host: ubuntu)
      final rpi5 = include.firstWhere((e) => e['target'] == 'rpi5');
      final rpi4 = include.firstWhere((e) => e['target'] == 'rpi4');
      expect(rpi5['args'], '${f.path} --target rpi5');
      // Same image → shared extraction; only cpu tuning differs.
      expect(rpi5['sysroot_key'], rpi4['sysroot_key']);
      expect(rpi5['build_key'], isNot(rpi4['build_key']));
    },
  );

  test(
    '--host narrows to the intersection with supported_host_types',
    () async {
      final f = write('pi5.emb.yaml', _singleTarget);
      final include = await render([f.path, '--host', 'ubuntu']);
      expect(include, hasLength(1));
      expect(include.single['host'], 'ubuntu');
    },
  );

  test('--target emits only the named target', () async {
    final f = write('rpi.emb.yaml', _multiTarget);
    final include = await render([f.path, '--target', 'rpi4']);
    expect(include, hasLength(1));
    expect(include.single['target'], 'rpi4');
  });

  test('a directory globs *.emb.yaml', () async {
    write('pi5.emb.yaml', _singleTarget);
    write('rpi.emb.yaml', _multiTarget);
    final include = await render([tmp.path, '--host', 'ubuntu']);
    expect(include, hasLength(3)); // pi5 default + rpi5 + rpi4
  });

  test('a manifest without a cross: block is skipped', () async {
    final f = write('plain.emb.yaml', 'id: plain\ntype: app\n');
    final include = await render([f.path]);
    expect(include, isEmpty);
  });
}
