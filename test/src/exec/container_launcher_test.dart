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
        run: (exe, args, {environment}) async {
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
}
