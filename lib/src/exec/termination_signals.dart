import 'dart:async';
import 'dart:io';

/// The signals that ask emb to stop: Ctrl-C and `kill` / a CI cancel.
///
/// Windows has no SIGTERM to watch.
List<ProcessSignal> get terminationSignals => [
  ProcessSignal.sigint,
  if (!Platform.isWindows) ProcessSignal.sigterm,
];

/// The shell's exit code for a process killed by [signal]: 128 + its number.
int signalExitCode(ProcessSignal signal) =>
    128 + (signal == ProcessSignal.sigint ? 2 : 15);

/// Subscribes to a signal. Replaceable so tests need not signal themselves.
typedef SignalWatcher = Stream<ProcessSignal> Function(ProcessSignal signal);

Stream<ProcessSignal> _watch(ProcessSignal signal) => signal.watch();

/// Makes emb exit on SIGINT / SIGTERM when it is PID 1.
///
/// In the container the inner emb is PID 1, and the kernel only delivers a
/// signal to PID 1 if PID 1 has a handler for it. With none, the SIGINT the
/// runtime client forwards on Ctrl-C is dropped and the container builds on
/// after the host emb is gone. Exiting is all the handler has to do: when
/// PID 1 exits the kernel kills everything else in the PID namespace, so
/// flutter, ninja and git go with it.
///
/// Does nothing when emb is not PID 1, where the default disposition already
/// terminates it. Returns the subscriptions (empty in that case).
List<StreamSubscription<ProcessSignal>> exitOnTerminationWhenInit({
  int? processId,
  SignalWatcher watch = _watch,
  void Function(int code) exit = exit,
}) {
  if ((processId ?? pid) != 1) return const [];
  return [
    for (final s in terminationSignals)
      watch(s).listen((signal) => exit(signalExitCode(signal))),
  ];
}
