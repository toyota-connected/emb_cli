import 'dart:io';

import 'package:emb_cli/src/cross/offline_enforcement.dart';
import 'package:emb_cli/src/cross/process_runner.dart';
import 'package:test/test.dart';

/// A runner whose `unshare` probe returns [unshareExit], or throws
/// [ProcessException] to simulate `unshare` being absent.
ProcessRunner _runner({int? unshareExit}) =>
    (
      exe,
      args, {
      workingDirectory,
      environment,
      includeParentEnvironment = true,
      runInShell = false,
      output = ProcessOutputMode.capture,
      label,
    }) async {
      if (exe == 'unshare') {
        if (unshareExit == null) {
          throw const ProcessException('unshare', [], 'not found');
        }
        return RunResult(unshareExit, '', '');
      }
      return const RunResult(0, '', '');
    };

void main() {
  group('netnsWrap', () {
    test('wraps argv in a rootless net namespace, preserving the argv', () {
      final w = netnsWrap(['cargo', 'build', '--offline']);
      expect(w.take(3), ['unshare', '--net', '--map-root-user']);
      expect(w, containsAllInOrder(['cargo', 'build', '--offline']));
      // The shim gets a $0 placeholder so "$@" is exactly the real argv.
      final shimIdx = w.indexOf('emb-offline');
      expect(w.sublist(shimIdx + 1), ['cargo', 'build', '--offline']);
      expect(w, contains(r'ip link set lo up 2>/dev/null || true; exec "$@"'));
    });
  });

  group('netnsRunner', () {
    test(
      'runs the command through unshare, delegating to the inner runner',
      () async {
        String? gotExe;
        List<String>? gotArgs;
        String? gotCwd;
        Future<RunResult> inner(
          String exe,
          List<String> args, {
          String? workingDirectory,
          Map<String, String>? environment,
          bool includeParentEnvironment = true,
          bool runInShell = false,
          ProcessOutputMode output = ProcessOutputMode.capture,
          String? label,
        }) async {
          gotExe = exe;
          gotArgs = args;
          gotCwd = workingDirectory;
          return const RunResult(0, '', '');
        }

        await netnsRunner(inner)('cmake', [
          '--build',
          '.',
        ], workingDirectory: '/b');
        expect(gotExe, 'unshare');
        // The original command survives at the tail, after the shim.
        expect(gotArgs, containsAllInOrder(['cmake', '--build', '.']));
        // Named args pass through.
        expect(gotCwd, '/b');
      },
    );
  });

  group('netnsAvailable', () {
    test('true when the probe exits 0', () async {
      expect(await netnsAvailable(_runner(unshareExit: 0)), isTrue);
    });
    test('false when the probe fails (userns disabled)', () async {
      expect(await netnsAvailable(_runner(unshareExit: 1)), isFalse);
    });
    test('false when unshare is absent', () async {
      expect(await netnsAvailable(_runner()), isFalse);
    });
  });

  group('resolveOfflineEnforcement', () {
    test('off enforces nothing', () async {
      final e = await resolveOfflineEnforcement(
        OfflineMode.off,
        _runner(unshareExit: 1),
      );
      expect(e.wrap, isFalse);
      expect(e.fatal, isNull);
      expect(e.warning, isNull);
    });

    test('deny wraps when isolation is available', () async {
      final e = await resolveOfflineEnforcement(
        OfflineMode.deny,
        _runner(unshareExit: 0),
      );
      expect(e.wrap, isTrue);
      expect(e.fatal, isNull);
    });

    test(
      'deny degrades with a warning when isolation is unavailable',
      () async {
        final e = await resolveOfflineEnforcement(
          OfflineMode.deny,
          _runner(unshareExit: 1),
        );
        expect(e.wrap, isFalse);
        expect(e.fatal, isNull);
        expect(e.warning, isNotNull);
      },
    );

    test('strict wraps when isolation is available', () async {
      final e = await resolveOfflineEnforcement(
        OfflineMode.strict,
        _runner(unshareExit: 0),
      );
      expect(e.wrap, isTrue);
      expect(e.fatal, isNull);
    });

    test('strict fails closed when isolation is unavailable', () async {
      final e = await resolveOfflineEnforcement(
        OfflineMode.strict,
        _runner(unshareExit: 1),
      );
      expect(e.wrap, isFalse);
      expect(e.fatal, isNotNull);
      expect(e.fatal, contains('--offline-strict'));
    });
  });
}
