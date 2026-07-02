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

  /// Extra args to propagate this verbosity to `flutter build` — `--verbose`
  /// at [verbose]+, nothing otherwise.
  List<String> get flutterArgs =>
      streamsChildOutput ? const ['--verbose'] : const [];
}

/// The process-wide resolved verbosity, set once by the command runner after
/// parsing `-v`/`-vv`/`-q`/`--verbose`/`--quiet` (or `EMB_VERBOSITY`).
///
/// A deliberate global: commands are constructed before their arguments are
/// parsed, so a command reads this at run time to build a verbosity-aware
/// process runner and to choose streamed vs. spinner output. Tests may set it
/// directly and should reset it in `tearDown`.
Verbosity embVerbosity = Verbosity.normal;
