import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:emb_cli/src/commands/boards_command.dart';
import 'package:emb_cli/src/flutter/custom_devices_config.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:mocktail/mocktail.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

class _MockLogger extends Mock implements Logger {}

void main() {
  late Logger logger;
  late Directory tmp;
  final info = <String>[];
  final warn = <String>[];
  final err = <String>[];

  setUp(() {
    logger = _MockLogger();
    info.clear();
    warn.clear();
    err.clear();
    when(
      () => logger.info(any()),
    ).thenAnswer((i) => info.add('${i.positionalArguments.first}'));
    when(
      () => logger.warn(any()),
    ).thenAnswer((i) => warn.add('${i.positionalArguments.first}'));
    when(
      () => logger.err(any()),
    ).thenAnswer((i) => err.add('${i.positionalArguments.first}'));
    tmp = Directory.systemTemp.createTempSync('emb_bcd_');
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  /// HOME points into the temp dir, so the config lands at
  /// <tmp>/.config/flutter/custom_devices.json and never the developer's own.
  Map<String, String> env() => {'HOME': tmp.path};

  File configFile() =>
      File(p.join(tmp.path, '.config', 'flutter', 'custom_devices.json'));

  String board({String extra = ''}) {
    final f = File(p.join(tmp.path, 'board.emb.yaml'))
      ..writeAsStringSync('''
id: demo
type: board
cross:
  provider: arm-gnu
  triple: aarch64-none-linux-gnu
  targets:
    rpi5:
      sysroot: { source: device, host: pi@board }
      package: { name: ivi-homescreen, version: 1.0.0, bin: shell/homescreen }
      custom_device: { id: rpi5, label: Raspberry Pi 5 }
    agl:
      sysroot: { transport: adb, adb_serial: ABC123 }
      custom_device: { id: agl-board }
    buildonly:
      sysroot: { source: image, image_url: "https://e.com/x.img.xz" }
$extra''');
    return f.path;
  }

  Future<int> run(List<String> args) async {
    final runner = CommandRunner<int>('emb', 'test')
      ..addCommand(BoardsCommand(logger: logger, environment: env()));
    return await runner.run(['boards', 'custom-devices', ...args]) ?? 0;
  }

  test('registers every target that declares a custom_device', () async {
    final rc = await run([board()]);
    expect(rc, ExitCode.success.code);

    final ids = readCustomDevices(configFile()).map((d) => d['id']).toList();
    // `buildonly` declares no block and is silently skipped.
    expect(ids, ['rpi5', 'agl-board']);
  });

  test('--target registers just that one', () async {
    await run([board(), '--target', 'agl']);
    final devices = readCustomDevices(configFile());
    expect(devices, hasLength(1));
    expect(devices.single['id'], 'agl-board');
    // Derived from the target's adb transport, not restated in the board file.
    expect(devices.single['ping'], ['adb', '-s', 'ABC123', 'shell', 'true']);
  });

  test('re-running updates in place rather than duplicating', () async {
    await run([board(), '--target', 'rpi5']);
    await run([board(), '--target', 'rpi5']);
    expect(readCustomDevices(configFile()), hasLength(1));
    expect(info.join('\n'), contains('Updated'));
  });

  test('an unrelated device in the config survives', () async {
    configFile()
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(
        jsonEncode({
          'custom-devices': [
            {'id': 'someone-else'},
          ],
        }),
      );
    await run([board(), '--target', 'rpi5']);
    expect(
      readCustomDevices(configFile()).map((d) => d['id']),
      containsAll(['someone-else', 'rpi5']),
    );
  });

  test('--deploy-dir flows into the generated commands', () async {
    await run([board(), '--target', 'rpi5', '--deploy-dir', '/opt/ihs']);
    final d = readCustomDevices(configFile()).single;
    expect((d['runDebug']! as List).last, contains("cd '/opt/ihs'"));
    expect(
      (d['uninstall']! as List).last,
      contains('/opt/ihs/data/flutter_assets'),
    );
  });

  test('the embedder name comes from package.bin', () async {
    await run([board(), '--target', 'rpi5']);
    final d = readCustomDevices(configFile()).single;
    // `shell/homescreen` → `homescreen`: the name inside the bundle.
    expect((d['runDebug']! as List).last, contains('./homescreen -b .'));
  });

  test('--bin overrides it', () async {
    await run([board(), '--target', 'rpi5', '--bin', 'my-shell']);
    final d = readCustomDevices(configFile()).single;
    expect((d['runDebug']! as List).last, contains('./my-shell -b .'));
  });

  test('--dry-run writes nothing', () async {
    final rc = await run([board(), '--dry-run']);
    expect(rc, ExitCode.success.code);
    expect(configFile().existsSync(), isFalse);
    expect(info.join('\n'), contains('"id": "rpi5"'));
  });

  test('a target with no custom_device is reported, not registered', () async {
    final rc = await run([board(), '--target', 'buildonly']);
    expect(rc, ExitCode.usage.code);
    expect(warn.join('\n'), contains('no cross.custom_device'));
    expect(configFile().existsSync(), isFalse);
  });

  test('an unknown target names the ones that exist', () async {
    final rc = await run([board(), '--target', 'nope']);
    expect(rc, ExitCode.usage.code);
    expect(err.join('\n'), contains('unknown target "nope"'));
  });

  test('a missing manifest fails cleanly', () async {
    final rc = await run([p.join(tmp.path, 'absent.emb.yaml')]);
    expect(rc, ExitCode.noInput.code);
  });

  test('an ssh target with no host is rejected before writing', () async {
    File(p.join(tmp.path, 'nohost.emb.yaml')).writeAsStringSync('''
id: demo
type: board
cross:
  provider: arm-gnu
  triple: aarch64-none-linux-gnu
  targets:
    x:
      custom_device: { id: x }
''');
    final rc = await run([p.join(tmp.path, 'nohost.emb.yaml')]);
    expect(rc, ExitCode.config.code);
    expect(err.join('\n'), contains('needs a host'));
    expect(configFile().existsSync(), isFalse);
  });
}
