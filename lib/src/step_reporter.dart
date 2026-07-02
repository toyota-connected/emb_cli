import 'package:emb_cli/src/verbosity.dart';
import 'package:mason_logger/mason_logger.dart';

/// Reports a long step as an animated spinner at normal verbosity, but as
/// plain start/done banners at `-v`+ — where an animated spinner rewrites the
/// current line and would garble streamed child-process output.
///
/// `start` returns a [StepHandle] exposing the subset of mason_logger's
/// `Progress` API used by the commands, so call sites migrate by swapping
/// `logger.progress(msg)` for `reporter.start(msg)`.
class StepReporter {
  /// Logs to the given logger; the presentation is chosen from [verbosity],
  /// defaulting to the process-wide [embVerbosity].
  StepReporter(this._logger, {Verbosity? verbosity})
    : _plain = (verbosity ?? embVerbosity).streamsChildOutput;

  final Logger _logger;
  final bool _plain;

  /// Begin a step labelled [message].
  StepHandle start(String message) => _plain
      ? _PlainStep(_logger, message)
      : _SpinnerStep(_logger.progress(message));
}

/// A running step. Complete or fail it exactly once; [update] revises the label
/// mid-flight.
abstract class StepHandle {
  /// Mark the step done, optionally replacing its label.
  void complete([String? message]);

  /// Mark the step failed, optionally with a message.
  void fail([String? message]);

  /// Revise the in-flight label.
  void update(String message);
}

class _SpinnerStep implements StepHandle {
  _SpinnerStep(this._progress);
  final Progress _progress;
  @override
  void complete([String? message]) => _progress.complete(message);
  @override
  void fail([String? message]) => _progress.fail(message);
  @override
  void update(String message) => _progress.update(message);
}

class _PlainStep implements StepHandle {
  _PlainStep(this._logger, this._message) : _sw = Stopwatch()..start() {
    _logger.info('▶ $_message');
  }
  final Logger _logger;
  final String _message;
  final Stopwatch _sw;

  String get _elapsed =>
      '${(_sw.elapsedMilliseconds / 1000).toStringAsFixed(1)}s';

  @override
  void complete([String? message]) {
    _sw.stop();
    _logger.info('✓ ${message ?? _message} ($_elapsed)');
  }

  @override
  void fail([String? message]) {
    _sw.stop();
    _logger.err('✗ ${message ?? _message} ($_elapsed)');
  }

  @override
  void update(String message) => _logger.info('  $message');
}
