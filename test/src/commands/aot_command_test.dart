import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:emb_cli/src/commands/aot_command.dart';
import 'package:emb_cli/src/exec/container_launcher.dart';
import 'package:emb_cli/src/exec/container_reentry.dart';
import 'package:emb_cli/src/host/host_info.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:test/test.dart';

HostInfo _mac() => const HostInfo(
  os: HostOs.macos,
  machineArch: 'arm64',
  archAliases: <String>{},
  hostType: 'darwin',
  versionId: '14',
);

void main() {
  test('a non-linux host routes `emb aot` through the container', () async {
    final tmp = Directory.systemTemp.createTempSync('emb-aot-route-');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final app = Directory('${tmp.path}/app')..createSync();

    List<String>? seenArgs;
    final reentry = ContainerReentry(
      host: _mac(),
      image: 'ghcr.io/x/runtime:latest',
      launcher: ContainerLauncher(
        run: (exe, args) async {
          seenArgs = args;
          return ProcessResult(0, 0, '', '');
        },
      ),
    );

    final runner = CommandRunner<int>(
      'emb',
      'test',
    )..addCommand(AotCommand(logger: Logger(), host: _mac(), reentry: reentry));

    final code = await runner.run([
      'aot',
      '--app-path',
      app.path,
      '-w',
      tmp.path,
    ]);

    expect(code, ExitCode.success.code);
    expect(seenArgs, isNotNull);
    expect(seenArgs!.first, 'run');
    expect(seenArgs!.last, '--exec-native');
    // Must NOT forward -w: the container's $FLUTTER_WORKSPACE resolves the
    // Linux Flutter SDK; the host workspace would resolve macOS binaries.
    final embArgStart = seenArgs!.indexOf('emb');
    final embArgs = seenArgs!.sublist(embArgStart + 1);
    expect(embArgs, isNot(contains('-w')));
    // Neither obfuscate flag should appear when the user didn't pass one.
    expect(embArgs, isNot(contains('--obfuscate')));
    expect(embArgs, isNot(contains('--no-obfuscate')));
  });

  test(
    'container re-entry forwards --no-strip and --no-obfuscate when passed',
    () async {
      final tmp = Directory.systemTemp.createTempSync('emb-aot-flags-');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final app = Directory('${tmp.path}/app')..createSync();

      List<String>? seenArgs;
      final reentry = ContainerReentry(
        host: _mac(),
        image: 'ghcr.io/x/runtime:latest',
        launcher: ContainerLauncher(
          run: (exe, args) async {
            seenArgs = args;
            return ProcessResult(0, 0, '', '');
          },
        ),
      );

      final runner = CommandRunner<int>('emb', 'test')
        ..addCommand(
          AotCommand(logger: Logger(), host: _mac(), reentry: reentry),
        );

      final code = await runner.run([
        'aot',
        '--app-path',
        app.path,
        '-w',
        tmp.path,
        '--no-strip',
        '--no-obfuscate',
      ]);

      expect(code, ExitCode.success.code);
      final embArgStart = seenArgs!.indexOf('emb');
      final embArgs = seenArgs!.sublist(embArgStart + 1);
      expect(embArgs, contains('--no-strip'));
      expect(embArgs, contains('--no-obfuscate'));
    },
  );
}
