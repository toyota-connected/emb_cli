import 'dart:io';

import 'package:emb_cli/src/exec/container_launcher.dart';
import 'package:test/test.dart';

void main() {
  test('argv mounts, sets the recursion guard, and appends --exec-native', () {
    final argv = ContainerLauncher.argv(
      image: 'ghcr.io/acme/emb-engine-builder:key',
      embArgs: const ['engine', '--build-engine', '--commit', 'abc'],
      mounts: const [Mount('/proj'), Mount('/dart', readOnly: true)],
      workdir: '/proj',
    );
    expect(argv.first, 'run');
    expect(argv, contains('--rm'));
    expect(argv, containsAllInOrder(<String>['-v', '/proj:/proj']));
    expect(argv, containsAllInOrder(<String>['-v', '/dart:/dart:ro']));
    expect(argv, containsAllInOrder(<String>['-w', '/proj']));
    expect(argv, containsAllInOrder(<String>['-e', 'EMB_IN_CONTAINER=1']));

    // `emb` immediately follows the image, and the guard flag is last.
    final imgIdx = argv.indexOf('ghcr.io/acme/emb-engine-builder:key');
    expect(argv[imgIdx + 1], 'emb');
    expect(argv.last, '--exec-native');
  });

  test(
    'run uses the configured tool and returns the inner exit code',
    () async {
      String? seenTool;
      List<String>? seenArgs;
      final launcher = ContainerLauncher(
        tool: 'podman',
        run: (exe, args) async {
          seenTool = exe;
          seenArgs = args;
          return ProcessResult(0, 7, '', '');
        },
      );
      final code = await launcher.run(
        image: 'img',
        embArgs: const ['engine', '--build-engine'],
      );
      expect(seenTool, 'podman');
      expect(seenArgs, isNotNull);
      expect(seenArgs!.last, '--exec-native');
      expect(code, 7);
    },
  );

  test(
    'run throws ContainerToolNotFound when tool binary is missing',
    () async {
      final launcher = ContainerLauncher(
        run: (exe, args) async =>
            throw ProcessException(exe, args, 'No such file or directory', 2),
      );
      expect(
        () => launcher.run(image: 'img', embArgs: const ['aot']),
        throwsA(
          isA<ContainerToolNotFound>()
              .having((e) => e.tool, 'tool', 'docker')
              .having((e) => e.message, 'message', contains('No such file')),
        ),
      );
    },
  );

  test(
    'run returns exit code 127 from the container without throwing',
    () async {
      final launcher = ContainerLauncher(
        run: (exe, args) async => ProcessResult(0, 127, '', ''),
      );
      final code = await launcher.run(image: 'img', embArgs: const ['aot']);
      expect(code, 127);
    },
  );

  test('default runner completes and does not hang', () async {
    // A fixture script that prints lines and exits — exercises the real
    // _defaultRunner without needing a container runtime.
    final dir = Directory.systemTemp.createTempSync('emb_test_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final script = File('${dir.path}/fixture.sh')
      ..writeAsStringSync(
        '#!/bin/sh\nfor i in \$(seq 1 200); do echo "line \$i"; done\n',
      );
    Process.runSync('chmod', ['+x', script.path]);

    final launcher = ContainerLauncher(tool: script.path);
    // The script ignores argv, so the container args are harmless noise.
    final code = await launcher
        .run(image: 'unused', embArgs: const [])
        .timeout(const Duration(seconds: 5));
    expect(code, 0);
  }, tags: 'integration');

  // The default runner must hand the child this process's own stdio. Piped
  // instead, the child gets a stdin nobody closes (anything that prompts
  // inside the container hangs run() forever) and loses the terminal. A
  // fixture that only writes cannot tell the two apart, and one that reads
  // stdin would block a run started from a terminal, so compare the fds.
  test(
    'default runner gives the child the parent stdio, not pipes',
    () async {
      final dir = Directory.systemTemp.createTempSync('emb_test_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final out = File('${dir.path}/fds');
      // Written through fd 3, so the redirect leaves 0, 1 and 2 as inherited.
      final script = File('${dir.path}/fixture.sh')
        ..writeAsStringSync(
          '#!/bin/sh\n'
          'exec 3> "${out.path}"\n'
          r'for fd in 0 1 2; do readlink /proc/$$/fd/$fd >&3; done'
          '\n',
        );
      Process.runSync('chmod', ['+x', script.path]);

      final code = await ContainerLauncher(tool: script.path)
          .run(image: 'unused', embArgs: const [])
          .timeout(const Duration(seconds: 5));
      expect(code, 0);

      final mine = [
        for (final fd in [0, 1, 2]) Link('/proc/self/fd/$fd').targetSync(),
      ];
      expect(out.readAsLinesSync(), mine);
    },
    tags: 'integration',
    testOn: 'linux',
  );
}
