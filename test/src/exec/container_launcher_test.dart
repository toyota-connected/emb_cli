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

  group('-i / -t', () {
    List<String> flags(List<String> argv) => [
      for (final a in argv.takeWhile((a) => a != 'img'))
        if (a == '-i' || a == '-t') a,
    ];

    test('argv emits neither by default', () {
      final argv = ContainerLauncher.argv(image: 'img', embArgs: const []);
      expect(flags(argv), isEmpty);
    });

    // Runtime options, so they sit before the image: after it they would be
    // arguments to emb.
    test('argv puts them right after --rm', () {
      final argv = ContainerLauncher.argv(
        image: 'img',
        embArgs: const ['aot'],
        mounts: const [Mount('/ws')],
        interactive: true,
        tty: true,
      );
      expect(argv.take(4), ['run', '--rm', '-i', '-t']);
      expect(argv.skipWhile((a) => a != 'img').skip(1), [
        'emb',
        'aot',
        '--exec-native',
      ]);
    });

    for (final (interactive, tty, want) in [
      (false, false, <String>[]),
      (true, false, ['-i']),
      (false, true, ['-t']),
      (true, true, ['-i', '-t']),
    ]) {
      test('run passes interactive=$interactive tty=$tty through', () async {
        List<String>? seen;
        final launcher = ContainerLauncher(
          run: (exe, args) async {
            seen = args;
            return ProcessResult(0, 0, '', '');
          },
          interactive: interactive,
          tty: tty,
        );
        await launcher.run(image: 'img', embArgs: const []);
        expect(flags(seen!), want);
      });
    }
  });

  group('foregroundFromStat', () {
    // pid (comm) state ppid pgrp session tty_nr tpgid flags …
    test('true when pgrp is the terminal foreground group', () {
      expect(
        foregroundFromStat('42 (emb) R 7 42 7 34816 42 4194304 0'),
        isTrue,
      );
    });

    test('false for a background job', () {
      expect(
        foregroundFromStat('42 (emb) R 7 42 7 34816 99 4194304 0'),
        isFalse,
      );
    });

    test('false with no controlling terminal (tpgid -1)', () {
      expect(foregroundFromStat('42 (emb) R 7 42 7 0 -1 4194304 0'), isFalse);
    });

    test('counts fields from the last ")" of the command name', () {
      expect(
        foregroundFromStat('42 (a) b (1 2 3 4 5 6) S 7 42 7 34816 42 0'),
        isTrue,
      );
      expect(
        foregroundFromStat('42 (a) b (1 2 3 4 5 6) S 7 42 7 34816 99 0'),
        isFalse,
      );
    });

    test('false for unparseable input', () {
      expect(foregroundFromStat(''), isFalse);
      expect(foregroundFromStat('42 (emb) R 7'), isFalse);
      expect(foregroundFromStat('42 (emb) R 7 x 7 0 x 0'), isFalse);
    });
  });

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
      // Read into variables first and write once at the end. Any redirect on
      // the readlink itself shows up in the answer: dash applies a simple
      // command's redirects in the parent shell before it forks, so
      // `readlink /proc/$$/fd/1 > file` reports the file.
      final script = File('${dir.path}/fixture.sh')
        ..writeAsStringSync(
          '#!/bin/sh\n'
          r'a=$(readlink /proc/$$/fd/0)'
          '\n'
          r'b=$(readlink /proc/$$/fd/1)'
          '\n'
          r'c=$(readlink /proc/$$/fd/2)'
          '\n'
          r'printf "%s\n" "$a" "$b" "$c"'
          ' > "${out.path}"\n',
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
