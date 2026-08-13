import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:emb_cli/src/commands/build_command.dart';
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
  test('a non-linux host routes `emb build` through the container', () async {
    final tmp = Directory.systemTemp.createTempSync('emb-build-route-');
    addTearDown(() => tmp.deleteSync(recursive: true));
    // A self-describing package with a build matrix, plus its app dir.
    final pkg = Directory(p.join(tmp.path, 'my_app'))..createSync();
    File(p.join(pkg.path, 'emb.yaml')).writeAsStringSync('''
id: my_app
type: app
build:
  app_path: .
  archs: [arm64]
  modes: [release]
''');

    List<String>? seenArgs;
    final reentry = ContainerReentry(
      host: _mac(),
      image: 'ghcr.io/x/runtime:latest',
      launcher: ContainerLauncher(
        run: (exe, args, {environment}) async {
          seenArgs = args;
          return ProcessResult(0, 0, '', '');
        },
      ),
    );

    final runner = CommandRunner<int>('emb', 'test')
      ..addCommand(
        BuildCommand(logger: Logger(), host: _mac(), reentry: reentry),
      );

    final code = await runner.run(['build', pkg.path, '-w', tmp.path]);

    expect(code, ExitCode.success.code);
    // Re-entry carries the package dir (absolute) and the recursion guard.
    expect(seenArgs, contains(pkg.absolute.path));
    expect(seenArgs!.first, 'run'); // docker/podman argv
    expect(seenArgs!.last, '--exec-native');
  });
}
