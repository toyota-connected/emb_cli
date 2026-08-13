import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:emb_cli/src/commands/bundle_command.dart';
import 'package:emb_cli/src/exec/container_launcher.dart';
import 'package:emb_cli/src/exec/container_reentry.dart';
import 'package:emb_cli/src/host/host_info.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

HostInfo _mac() => const HostInfo(
  os: HostOs.macos,
  machineArch: 'arm64',
  archAliases: <String>{},
  hostType: 'darwin',
  versionId: '14',
);

void main() {
  test('a non-linux host routes bundle through the container', () async {
    final tmp = Directory.systemTemp.createTempSync('emb-bundle-route-');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final app = Directory(p.join(tmp.path, 'app'))..createSync();

    var launched = false;
    List<String>? seenArgs;
    final reentry = ContainerReentry(
      host: _mac(),
      image: 'ghcr.io/x/runtime:latest',
      launcher: ContainerLauncher(
        run: (exe, args, {environment}) async {
          launched = true;
          seenArgs = args;
          return ProcessResult(0, 0, '', '');
        },
      ),
    );

    final runner = CommandRunner<int>('emb', 'test')
      ..addCommand(
        BundleCommand(
          logger: Logger(),
          host: _mac(),
          reentry: reentry,
          bundleFactory: (_) => throw StateError('must not build natively'),
          aotFactory: (_, _) => throw StateError('must not build natively'),
        ),
      );

    final code = await runner.run([
      'bundle',
      '--app-path',
      app.path,
      '-w',
      tmp.path,
      '--arch',
      'arm64',
      '--build',
    ]);

    expect(code, ExitCode.success.code);
    expect(
      launched,
      isTrue,
      reason: 'the build must be routed to the container',
    );
    // The re-entry carries the app path and the recursion guard.
    expect(
      seenArgs,
      containsAllInOrder(<String>['--app-path', app.absolute.path]),
    );
    expect(seenArgs, contains('--build'));
    expect(seenArgs!.last, '--exec-native');
  });
}
