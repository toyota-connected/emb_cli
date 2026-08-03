/// Where a resolved interactivity mode came from.
///
/// Reported at verbose level so an operator can see *why* a run behaved the
/// way it did. With no environment sniffing, every source below is something
/// the operator wrote — which is the point.
enum InteractivitySource {
  /// `--interactive` / `--no-interactive` was passed explicitly.
  flag,

  /// The [Interactivity.envVar] environment variable opted out.
  environment,

  /// Nothing said otherwise, so the default applied.
  fallback,
}

/// Whether host package operations may prompt for authorization.
///
/// This is orthogonal to `--yes`, which only governs emb's own confirmation
/// prompt. Interactivity governs the `interactive` hint sent to the system
/// package daemon, and so whether polkit (or the platform equivalent) is
/// allowed to ask the user to authenticate.
///
/// Interactive is the unconditional default. Nothing about the environment
/// flips it: `CI`, `GITHUB_ACTIONS` and friends are deliberately not consulted,
/// because a mode that rides on ambient state is invisible in the command the
/// operator typed, and an unexpected *silent* authorization failure is far
/// worse than an unexpected prompt.
///
/// Non-interactive is not an authorization mechanism. It suppresses the
/// prompt; it does not grant anything.
class Interactivity {
  const Interactivity._(this.interactive, this.source);

  /// Resolve the mode, highest precedence first:
  ///
  /// 1. [explicit] — the `--[no-]interactive` flag, null when unset.
  /// 2. [envVar] in [environment].
  /// 3. Interactive.
  ///
  /// [environment] is injected rather than read from `Platform`, so this stays
  /// pure and table-testable.
  factory Interactivity.resolve({
    required Map<String, String> environment,
    bool? explicit,
  }) {
    if (explicit != null) {
      return Interactivity._(explicit, InteractivitySource.flag);
    }
    if (_optedOut(environment[envVar])) {
      return const Interactivity._(false, InteractivitySource.environment);
    }
    return const Interactivity._(true, InteractivitySource.fallback);
  }

  /// Opt out of interactive authorization without editing each command line.
  ///
  /// Intended for wrappers and workflow-level `env:` blocks. Any value other
  /// than empty, `0`, or `false` counts as set.
  static const envVar = 'EMB_NON_INTERACTIVE';

  /// Whether the package daemon may prompt for authorization.
  final bool interactive;

  /// What decided [interactive].
  final InteractivitySource source;

  static bool _optedOut(String? value) {
    if (value == null) return false;
    final v = value.trim().toLowerCase();
    return v.isNotEmpty && v != '0' && v != 'false';
  }

  /// One-line description for verbose logging, naming the deciding source.
  ///
  /// e.g. `non-interactive (--no-interactive)`, `interactive (default)`.
  String describe() {
    final mode = interactive ? 'interactive' : 'non-interactive';
    switch (source) {
      case InteractivitySource.flag:
        return '$mode (${interactive ? '--interactive' : '--no-interactive'})';
      case InteractivitySource.environment:
        return '$mode ($envVar)';
      case InteractivitySource.fallback:
        return '$mode (default)';
    }
  }

  @override
  String toString() => describe();
}
