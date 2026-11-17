import 'dart:async';
import 'dart:io';

import 'package:emb_cli/src/exec/termination_signals.dart';
import 'package:test/test.dart';

void main() {
  test('signalExitCode is 128 + the signal number', () {
    expect(signalExitCode(ProcessSignal.sigint), 130);
    expect(signalExitCode(ProcessSignal.sigterm), 143);
  });

  group('exitOnTerminationWhenInit', () {
    test('watches nothing when emb is not PID 1', () {
      final watched = <ProcessSignal>[];
      final subs = exitOnTerminationWhenInit(
        processId: 4242,
        watch: (s) {
          watched.add(s);
          return const Stream.empty();
        },
        exit: (_) => fail('must not exit'),
      );
      expect(subs, isEmpty);
      expect(watched, isEmpty);
    });

    test('as PID 1, exits 130 on SIGINT and 143 on SIGTERM', () async {
      final ctl = {
        for (final s in terminationSignals)
          s: StreamController<ProcessSignal>(sync: true),
      };
      final codes = <int>[];
      final subs = exitOnTerminationWhenInit(
        processId: 1,
        watch: (s) => ctl[s]!.stream,
        exit: codes.add,
      );
      addTearDown(() async {
        for (final s in subs) {
          await s.cancel();
        }
      });
      expect(subs, hasLength(terminationSignals.length));

      ctl[ProcessSignal.sigint]!.add(ProcessSignal.sigint);
      expect(codes, [130]);
      ctl[ProcessSignal.sigterm]?.add(ProcessSignal.sigterm);
      expect(codes, [130, if (!Platform.isWindows) 143]);
    });
  });
}
