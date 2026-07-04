import 'dart:io';

import 'package:emb_cli/src/cross/process_runner.dart';

/// How strictly an offline build denies the network.
enum OfflineMode {
  /// Online — no denial.
  off,

  /// Deny emb's own egress (cached inputs only) and best-effort sandbox build
  /// subprocesses; proceed even when real isolation is unavailable.
  deny,

  /// Require real isolation (a network namespace around build subprocesses);
  /// refuse to build when the host can't provide it, rather than silently
  /// falling back to a weaker guarantee.
  strict,
}

/// Wrap [argv] to run inside a fresh network namespace with only loopback
/// brought up, so any attempt to reach off-host fails fast instead of leaking
/// to the network. Rootless via a user namespace (`--map-root-user`), so it
/// needs no privileges — only unprivileged user namespaces enabled on the host.
///
/// The `sh -c` shim brings `lo` up (best-effort; a down loopback makes tools
/// that probe localhost hang on long timeouts) and then `exec`s the real argv.
/// The literal `emb-offline` is `$0` for the shim, so `"$@"` is exactly [argv].
List<String> netnsWrap(List<String> argv) => [
  'unshare',
  '--net',
  '--map-root-user',
  'sh',
  '-c',
  r'ip link set lo up 2>/dev/null || true; exec "$@"',
  'emb-offline',
  ...argv,
];

/// Whether the host can create a rootless network namespace — the probe is
/// `unshare --net --map-root-user true`. False when `unshare` is absent
/// (non-Linux) or unprivileged user namespaces are disabled (common on locked
/// down CI runners and inside many containers).
Future<bool> netnsAvailable(ProcessRunner run) async {
  try {
    final r = await run('unshare', [
      '--net',
      '--map-root-user',
      'true',
    ], output: ProcessOutputMode.capture);
    return r.exitCode == 0;
  } on ProcessException {
    return false; // unshare not installed
  }
}

/// The resolved offline enforcement for this run: whether to wrap build
/// subprocesses in a network namespace, and whether to refuse the build.
class OfflineEnforcement {
  const OfflineEnforcement({this.wrap = false, this.fatal, this.warning});

  /// Wrap build subprocesses with [netnsWrap].
  final bool wrap;

  /// Non-null when the build must be refused (strict mode, no isolation). The
  /// message explains why and how to proceed.
  final String? fatal;

  /// Non-null when enforcement is degraded but the build proceeds.
  final String? warning;
}

/// Resolve [mode] against the host's isolation capability. In [OfflineMode.off]
/// nothing is enforced. Otherwise, when a network namespace is available the
/// build is wrapped in one; when it isn't, [OfflineMode.strict] refuses the
/// build (fail closed) while [OfflineMode.deny] proceeds with a warning,
/// relying on the input-level denial (cached artifacts, `CARGO_NET_OFFLINE`).
Future<OfflineEnforcement> resolveOfflineEnforcement(
  OfflineMode mode,
  ProcessRunner run,
) async {
  if (mode == OfflineMode.off) return const OfflineEnforcement();
  if (await netnsAvailable(run)) {
    return const OfflineEnforcement(wrap: true);
  }
  if (mode == OfflineMode.strict) {
    return const OfflineEnforcement(
      fatal:
          'network isolation (unshare --net) is unavailable — refusing '
          '--offline-strict. Enable unprivileged user namespaces, or use '
          '--offline (best-effort) instead.',
    );
  }
  return const OfflineEnforcement(
    warning:
        'network isolation unavailable; build subprocesses are not sandboxed '
        '— relying on cached inputs and CARGO_NET_OFFLINE only. Use '
        '--offline-strict to require isolation.',
  );
}
