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
