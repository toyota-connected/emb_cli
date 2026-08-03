import 'dart:io';

import 'package:emb_cli/src/cross/process_runner.dart';
import 'package:emb_cli/src/host/auth_probe.dart';
import 'package:emb_cli/src/host/host_info.dart';
import 'package:test/test.dart';

HostInfo _host([HostOs os = HostOs.linux]) => HostInfo(
  os: os,
  machineArch: 'x86_64',
  archAliases: const {'x86_64'},
  hostType: 'fedora',
  versionId: '42',
);

/// Records every argv it sees and replies from [exitCodes] keyed by executable.
class _FakeRunner {
  _FakeRunner({this.exitCodes = const {}, this.missing = const {}});

  final Map<String, int> exitCodes;
  final Set<String> missing;
  final calls = <List<String>>[];

  Future<RunResult> call(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool includeParentEnvironment = true,
    bool runInShell = false,
    ProcessOutputMode output = ProcessOutputMode.capture,
    String? label,
  }) async {
    calls.add([executable, ...arguments]);
    if (missing.contains(executable)) {
      throw ProcessException(executable, arguments, 'not found', 2);
    }
    return RunResult(exitCodes[executable] ?? 0, '', '');
  }
}

void main() {
  group('probeAuthorization', () {
    test('exit 0 means already authorized', () async {
      final r = _FakeRunner(exitCodes: const {'pkcheck': 0, 'loginctl': 0});
      final result = await probeAuthorization(_host(), runProcess: r.call);
      expect(result.status, AuthStatus.authorized);
      expect(result.isReady, isTrue);
    });

    test('exit 2 means authentication is required', () async {
      final r = _FakeRunner(exitCodes: const {'pkcheck': 2, 'loginctl': 0});
      final result = await probeAuthorization(_host(), runProcess: r.call);
      expect(result.status, AuthStatus.authRequired);
      expect(result.isReady, isFalse);
      expect(result.canPrompt, isTrue);
      expect(result.detail, contains('prompted'));
    });

    test('exit 1 is a policy denial, not a missing prompt', () async {
      final r = _FakeRunner(exitCodes: const {'pkcheck': 1, 'loginctl': 0});
      final result = await probeAuthorization(_host(), runProcess: r.call);
      expect(result.status, AuthStatus.denied);
    });

    test('an unexpected exit code is unknown, never a failure', () async {
      final r = _FakeRunner(exitCodes: const {'pkcheck': 7, 'loginctl': 0});
      final result = await probeAuthorization(_host(), runProcess: r.call);
      expect(result.status, AuthStatus.unknown);
      expect(result.detail, contains('7'));
    });

    test('a missing pkcheck is unknown, not a failure', () async {
      final r = _FakeRunner(missing: const {'pkcheck'});
      final result = await probeAuthorization(_host(), runProcess: r.call);
      expect(result.status, AuthStatus.unknown);
      expect(result.detail, contains('pkcheck'));
    });

    test('non-Linux hosts are unknown and run nothing', () async {
      for (final os in const [HostOs.macos, HostOs.windows]) {
        final r = _FakeRunner();
        final result = await probeAuthorization(_host(os), runProcess: r.call);
        expect(result.status, AuthStatus.unknown);
        expect(r.calls, isEmpty, reason: 'must not shell out off Linux');
      }
    });

    // R7: the probe must never pop an authentication dialog as a side effect
    // of running a diagnostic. `-u` / --allow-user-interaction is what would
    // make pkcheck prompt, so it must never appear.
    test('never asks polkit for user interaction', () async {
      final r = _FakeRunner(exitCodes: const {'pkcheck': 2, 'loginctl': 0});
      await probeAuthorization(_host(), runProcess: r.call);
      final pkcheck = r.calls.firstWhere((c) => c.first == 'pkcheck');
      expect(pkcheck, isNot(contains('-u')));
      expect(pkcheck, isNot(contains('--allow-user-interaction')));
      expect(pkcheck, contains(packageInstallAction));
    });

    group('session detection', () {
      test('no session means a prompt cannot be shown', () async {
        final r = _FakeRunner(exitCodes: const {'pkcheck': 2, 'loginctl': 1});
        final result = await probeAuthorization(_host(), runProcess: r.call);
        expect(result.canPrompt, isFalse);
        expect(result.detail, contains('no login session'));
        expect(
          result.detail,
          contains('polkit rule'),
          reason: 'must point at the fix that works without a session',
        );
      });

      test('a missing loginctl leaves it undetermined', () async {
        final r = _FakeRunner(
          exitCodes: const {'pkcheck': 2},
          missing: const {'loginctl'},
        );
        final result = await probeAuthorization(_host(), runProcess: r.call);
        expect(result.canPrompt, isNull);
        expect(result.status, AuthStatus.authRequired);
      });
    });
  });
}
