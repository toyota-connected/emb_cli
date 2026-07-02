/// CLI output verbosity.
///
/// Resolved once from `-q`/`--quiet`, `-v`/`--verbose`, and `-vv` (or the
/// `EMB_VERBOSITY` env override) and threaded into `makeProcessRunner` so the
/// process layer knows whether to tee child output live.
library;

/// CLI output verbosity, ordered least→most output. [Verbosity.normal] is the
/// default; streaming of long build steps is enabled at [Verbosity.verbose]
/// and above — see [Verbosity.streamsChildOutput].
enum Verbosity {
  /// `-q` / `--quiet`: errors only.
  quiet,

  /// Default: info-level logging, spinners, child output captured silently.
  normal,

  /// `-v` / `--verbose`: stream live, line-prefixed child output.
  verbose,

  /// `-vv`: everything [verbose] does plus the resolved argv/env dumps.
  debug;

  /// Whether streamed (`ProcessOutputMode.stream`) child output should be teed
  /// to the console live rather than captured silently. True at [verbose]+.
  bool get streamsChildOutput => index >= Verbosity.verbose.index;
}
