import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:emb_cli/src/verbosity.dart';

/// How a child process's stdout/stderr are handled by a [ProcessRunner].
enum ProcessOutputMode {
  /// Fully buffer both streams and return them complete in the [RunResult].
  /// Use for quick probes and callers that parse the output as data
  /// (`command -v`, `dpkg-deb -c`, `readelf -d`, `uname -m`). The default.
  capture,

  /// A long-running build step. Its output is teed to the console live when
  /// the runner's [Verbosity] is verbose or above; otherwise it is
  /// captured for a failure message. (Live teeing and bounded retention are
  /// added on top of this seam; today `stream` buffers like [capture].)
  stream,

  /// Wire the child's stdout/stderr straight to the parent's TTY
  /// (`ProcessStartMode.inheritStdio`). Nothing is retained. Use for genuinely
  /// interactive sessions (ssh `--run`, launching the native embedder).
  inherit,
}

/// Result of a run: the exit code plus captured output.
///
/// A drop-in for the fields of `dart:io`'s [ProcessResult] that callers read —
/// [stdout]/[stderr] are typed `String`. In [ProcessOutputMode.capture] (and,
/// for now, [ProcessOutputMode.stream]) these hold the complete output; in
/// [ProcessOutputMode.inherit] they are empty (the output went to the TTY).
class RunResult {
  /// Creates a result with the given [exitCode] and captured [stdout]/[stderr].
  const RunResult(this.exitCode, this.stdout, this.stderr);

  /// The process exit code.
  final int exitCode;

  /// Captured standard output (empty for [ProcessOutputMode.inherit]).
  final String stdout;

  /// Captured standard error (empty for [ProcessOutputMode.inherit]).
  final String stderr;
}

/// An injectable process runner so providers, the overlay builder, the
/// packagers and the AOT builder can be unit-tested without spawning real
/// subprocesses.
///
/// Construct the production runner with [makeProcessRunner]; tests pass a fake
/// that returns canned [RunResult]s and records the argv it was called with.
typedef ProcessRunner =
    Future<RunResult> Function(
      String executable,
      List<String> arguments, {
      String? workingDirectory,
      Map<String, String>? environment,
      bool includeParentEnvironment,
      bool runInShell,
      ProcessOutputMode output,
      String? label,
    });

/// Like [ProcessRunner], but a call may set a wall-clock limit.
///
/// A separate seam rather than a parameter on [ProcessRunner]: adding one there
/// would make all 50-odd existing fakes declare a parameter they ignore, and
/// only the calls that reach the network actually need a limit.
///
/// A limit can only be enforced where the child is spawned — a wrapper around a
/// `Future<RunResult>` has no handle to kill, so a `.timeout()` on one leaves
/// the process running while the caller tears down the directory under it. That
/// is why this lives beside [makeProcessRunner] rather than above it.
typedef TimedProcessRunner =
    Future<RunResult> Function(
      String executable,
      List<String> arguments, {
      String? workingDirectory,
      Map<String, String>? environment,
      bool includeParentEnvironment,
      bool runInShell,
      ProcessOutputMode output,
      String? label,
      Duration? timeout,
    });

/// How long to let the pipes flush after the child has exited, before giving up
/// on them. Only reached when something other than the child still holds the
/// write end open.
const _pipeFlushGrace = Duration(seconds: 2);

/// The exit code reported for a run that hit its limit, matching GNU
/// `timeout(1)` so a caller that already prints an exit code says something
/// recognizable.
const timedOutExitCode = 124;

/// Builds a [TimedProcessRunner].
///
/// On expiry the child gets SIGTERM, then SIGKILL after [graceOnTimeout] if it
/// has not gone — a `git clone` wedged on a dead connection ignores the first.
/// The call then completes with [timedOutExitCode] and a stderr line naming the
/// limit, so callers that already surface stderr need no new error type.
///
/// The signal reaches the **direct child only**, which is all `dart:io` offers:
/// `Process.kill` takes no process group. Measured: a timed-out `sleep` leaves
/// nothing behind, while `sh -c 'sleep 30'` kills the shell and orphans the
/// sleep. So give a timed call the real executable rather than a shell
/// wrapper — every call that sets a limit today does.
TimedProcessRunner makeTimedProcessRunner({
  Duration graceOnTimeout = const Duration(seconds: 5),
}) {
  return (
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool includeParentEnvironment = true,
    bool runInShell = false,
    ProcessOutputMode output = ProcessOutputMode.capture,
    String? label,
    Duration? timeout,
  }) async {
    final proc = await Process.start(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      environment: environment,
      includeParentEnvironment: includeParentEnvironment,
      runInShell: runInShell,
      mode: output == ProcessOutputMode.inherit
          ? ProcessStartMode.inheritStdio
          : ProcessStartMode.normal,
    );

    var timedOut = false;
    Timer? killer;
    Timer? escalate;
    if (timeout != null) {
      killer = Timer(timeout, () {
        timedOut = true;
        proc.kill();
        escalate = Timer(
          graceOnTimeout,
          () => proc.kill(ProcessSignal.sigkill),
        );
      });
    }

    try {
      // Collect into buffers while the child runs — a child that fills a pipe
      // buffer blocks, and a blocked child never exits, so the pipes have to be
      // drained concurrently with waiting on the exit code.
      final out = StringBuffer();
      final err = StringBuffer();
      final drained = output == ProcessOutputMode.inherit
          ? const <Future<void>>[]
          : <Future<void>>[
              proc.stdout.transform(utf8.decoder).forEach(out.write),
              proc.stderr.transform(utf8.decoder).forEach(err.write),
            ];

      // The exit code is the authoritative signal, not the pipes closing. A
      // grandchild can hold the write end open after the child is gone — `sh -c
      // 'trap "" TERM; sleep 30'` leaves exactly that behind — and waiting on
      // the streams then outlives the kill, which is the hang a timeout exists
      // to prevent. So wait on the exit, then give the pipes a short grace to
      // flush and stop caring.
      final code = await proc.exitCode;
      if (drained.isNotEmpty) {
        await Future.wait(
          drained,
        ).timeout(_pipeFlushGrace, onTimeout: () => const <void>[]);
      }
      if (timedOut) {
        final cmd = [executable, ...arguments].join(' ');
        return RunResult(
          timedOutExitCode,
          out.toString(),
          [
            if (err.isNotEmpty) err.toString().trimRight(),
            'timed out after ${timeout!.inSeconds}s: $cmd',
          ].join('\n'),
        );
      }
      return RunResult(code, out.toString(), err.toString());
    } finally {
      killer?.cancel();
      escalate?.cancel();
    }
  };
}

final TimedProcessRunner _defaultTimedRunner = makeTimedProcessRunner();

/// The default production [TimedProcessRunner] (a top-level function so it can
/// be a default parameter value).
Future<RunResult> defaultTimedProcessRunner(
  String executable,
  List<String> arguments, {
  String? workingDirectory,
  Map<String, String>? environment,
  bool includeParentEnvironment = true,
  bool runInShell = false,
  ProcessOutputMode output = ProcessOutputMode.capture,
  String? label,
  Duration? timeout,
}) => _defaultTimedRunner(
  executable,
  arguments,
  workingDirectory: workingDirectory,
  environment: environment,
  includeParentEnvironment: includeParentEnvironment,
  runInShell: runInShell,
  output: output,
  label: label,
  timeout: timeout,
);

/// Builds the production [ProcessRunner].
///
/// [verbosity] governs whether [ProcessOutputMode.stream] steps are teed live;
/// when null it is read from the global [embVerbosity] on each call, so the
/// default runner tracks `-v` without being rebuilt. [out]/[err] default to the
/// process's stdout/stderr and exist so tests can redirect. The `label` on a
/// call is a line prefix for streamed output (e.g. `cmake:drm-kms-egl`).
ProcessRunner makeProcessRunner({
  Verbosity? verbosity,
  IOSink? out,
  IOSink? err,
}) {
  return (
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool includeParentEnvironment = true,
    bool runInShell = false,
    ProcessOutputMode output = ProcessOutputMode.capture,
    String? label,
  }) async {
    if (output == ProcessOutputMode.inherit) {
      final proc = await Process.start(
        executable,
        arguments,
        workingDirectory: workingDirectory,
        environment: environment,
        includeParentEnvironment: includeParentEnvironment,
        runInShell: runInShell,
        mode: ProcessStartMode.inheritStdio,
      );
      return RunResult(await proc.exitCode, '', '');
    }

    if (output == ProcessOutputMode.stream) {
      final proc = await Process.start(
        executable,
        arguments,
        workingDirectory: workingDirectory,
        environment: environment,
        includeParentEnvironment: includeParentEnvironment,
        runInShell: runInShell,
      );
      final prefix = (label == null || label.isEmpty) ? '' : '[$label] ';
      final live = (verbosity ?? embVerbosity).streamsChildOutput;
      final outTail = _TailBuffer();
      final errTail = _TailBuffer();

      // Always drain both pipes (or the child blocks once a buffer fills);
      // retain a bounded tail for diagnostics and, when verbose, tee live.
      Future<void> pump(Stream<List<int>> src, _TailBuffer tail, IOSink sink) {
        return src
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .forEach((line) {
              tail.add(line);
              if (live) sink.writeln('$prefix$line');
            });
      }

      await Future.wait([
        pump(proc.stdout, outTail, out ?? stdout),
        pump(proc.stderr, errTail, err ?? stderr),
      ]);
      return RunResult(await proc.exitCode, outTail.text, errTail.text);
    }

    // capture: fully buffer both streams, preserving the exact bytes callers
    // parse (`command -v`, `dpkg-deb -c/-f`, `readelf -d`, `uname -m`).
    final result = await Process.run(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      environment: environment,
      includeParentEnvironment: includeParentEnvironment,
      runInShell: runInShell,
    );
    return RunResult(
      result.exitCode,
      (result.stdout as String?) ?? '',
      (result.stderr as String?) ?? '',
    );
  };
}

/// A bounded ring buffer of the most recent output lines. Lets a failed
/// [ProcessOutputMode.stream] step show a diagnostic tail without retaining an
/// entire multi-minute build log in memory.
class _TailBuffer {
  static const _maxLines = 200;
  static const _maxBytes = 64 * 1024;

  final List<String> _lines = [];
  int _bytes = 0;

  void add(String line) {
    _lines.add(line);
    _bytes += line.length + 1;
    while (_lines.length > _maxLines ||
        (_bytes > _maxBytes && _lines.length > 1)) {
      _bytes -= _lines.removeAt(0).length + 1;
    }
  }

  String get text => _lines.join('\n');
}

/// A [ProcessRunner] that merges [extra] into every call's environment (extra
/// keys win) before delegating to [inner]. `includeParentEnvironment` stays
/// true, so this layers over the ambient environment rather than replacing it —
/// used to point a build's subprocesses at a store-rooted `PUB_CACHE`.
ProcessRunner withEnv(ProcessRunner inner, Map<String, String> extra) =>
    (
      String executable,
      List<String> arguments, {
      String? workingDirectory,
      Map<String, String>? environment,
      bool includeParentEnvironment = true,
      bool runInShell = false,
      ProcessOutputMode output = ProcessOutputMode.capture,
      String? label,
    }) => inner(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      environment: {...?environment, ...extra},
      includeParentEnvironment: includeParentEnvironment,
      runInShell: runInShell,
      output: output,
      label: label,
    );

final ProcessRunner _defaultRunner = makeProcessRunner();

/// The default production [ProcessRunner] at [Verbosity.normal]. Used as the
/// fallback for constructors that inject a runner (a top-level function so it
/// stays a const tear-off usable as a default parameter value).
Future<RunResult> defaultProcessRunner(
  String executable,
  List<String> arguments, {
  String? workingDirectory,
  Map<String, String>? environment,
  bool includeParentEnvironment = true,
  bool runInShell = false,
  ProcessOutputMode output = ProcessOutputMode.capture,
  String? label,
}) => _defaultRunner(
  executable,
  arguments,
  workingDirectory: workingDirectory,
  environment: environment,
  includeParentEnvironment: includeParentEnvironment,
  runInShell: runInShell,
  output: output,
  label: label,
);
