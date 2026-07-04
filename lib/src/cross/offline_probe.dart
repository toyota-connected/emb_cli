/// A single check in an offline-buildability probe: is one input of an offline
/// build present, or one capability available?
class ProbeCheck {
  const ProbeCheck(this.name, {required this.ok, this.detail = ''});

  final String name;
  final bool ok;

  /// A short remediation or status note (e.g. `run emb fetch`, `available`).
  final String detail;

  Map<String, Object?> toData() => {
    'name': name,
    'ok': ok,
    if (detail.isNotEmpty) 'detail': detail,
  };
}

/// The verdict of `emb doctor --offline-probe`: a target can build with the
/// network denied iff every check passed. This certifies the *closure* is
/// materialized (toolchain, sysroot, vendored crates) without running a build,
/// so it stays a seconds-scale preflight rather than a full compile.
class OfflineProbe {
  const OfflineProbe({required this.target, required this.checks});

  final String target;
  final List<ProbeCheck> checks;

  bool get ok => checks.every((c) => c.ok);

  Map<String, Object?> toData() => {
    'target': target,
    'ok': ok,
    'checks': [for (final c in checks) c.toData()],
  };
}
