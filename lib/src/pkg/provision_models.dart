/// The plan produced by a dry-run (`HostProvisioner.simulate`): the packages
/// that would actually change if the install ran now.
class ProvisionPlan {
  const ProvisionPlan({
    required this.requested,
    required this.toInstall,
    this.additional = const [],
    this.unresolved = const [],
  });

  /// An empty plan (nothing to do).
  static const ProvisionPlan empty = ProvisionPlan(
    requested: [],
    toInstall: [],
  );

  /// The package names that were requested.
  final List<String> requested;

  /// The package identifiers/names that would be installed (the requested
  /// packages that are not already present).
  final List<String> toInstall;

  /// Additional dependencies that would be pulled in transitively.
  final List<String> additional;

  /// Requested packages that could not be resolved to an installable package
  /// (no provider, or an ambiguous set of providers, or an external repo not
  /// configured).
  final List<String> unresolved;

  bool get isEmpty => toInstall.isEmpty && additional.isEmpty;

  int get changeCount => toInstall.length + additional.length;
}

/// Progress event emitted while an install transaction runs.
class ProvisionProgress {
  const ProvisionProgress({required this.label, this.percent});

  /// Human-readable progress label (e.g. the package being installed).
  final String label;

  /// 0-100 when known, otherwise null.
  final int? percent;
}

/// Why an install failed, classified by the backend.
///
/// Exists so the command layer can present remediation without string-matching
/// backend error text: the same denial reads differently across dnf, apt and
/// zypper, and the text is not a stable interface.
enum ProvisionFailure {
  /// The system refused to authorize the operation.
  ///
  /// The daemon reports this identically whether it could not prompt or
  /// prompted and was denied, so the two cannot be distinguished from the
  /// error alone — the caller must use its own interactivity setting to decide
  /// what to suggest.
  notAuthorized,

  /// One or more requested names had no installable package.
  unresolved,

  /// The backend daemon or CLI was unreachable.
  daemonUnavailable,

  /// Anything else; consult [ProvisionResult.message].
  other,
}

/// The outcome of an `HostProvisioner.install` call.
class ProvisionResult {
  const ProvisionResult({
    required this.installed,
    this.failed = const [],
    this.message,
    this.kind,
  });

  /// Packages that were successfully installed (or already present).
  final List<String> installed;

  /// Packages that failed to install.
  final List<String> failed;

  /// Optional human-readable detail (error text on failure).
  final String? message;

  /// Classification of the failure, or null when [success] or unclassified.
  final ProvisionFailure? kind;

  bool get success => failed.isEmpty;
}

/// Raised when a provisioning operation fails irrecoverably.
class ProvisionException implements Exception {
  const ProvisionException(this.message);
  final String message;
  @override
  String toString() => 'ProvisionException: $message';
}
