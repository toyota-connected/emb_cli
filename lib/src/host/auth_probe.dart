import 'dart:io';

import 'package:emb_cli/src/cross/process_runner.dart';
import 'package:emb_cli/src/host/host_info.dart';

/// Whether the caller may perform a privileged host package operation.
enum AuthStatus {
  /// Already authorized — a polkit rule or a cached authorization covers it.
  /// An install will proceed with no prompt.
  authorized,

  /// Authentication is required. An install succeeds only if something can
  /// answer the prompt; see [AuthProbeResult.canPrompt].
  authRequired,

  /// Policy refuses this caller outright. Authenticating will not help.
  denied,

  /// Could not determine — `pkcheck` absent, or a non-Linux host.
  unknown,
}

/// Outcome of a non-mutating authorization probe.
class AuthProbeResult {
  const AuthProbeResult(this.status, {this.canPrompt, this.detail});

  /// What polkit said about this caller and action.
  final AuthStatus status;

  /// Whether an authentication prompt could actually reach the user, i.e.
  /// whether this process belongs to a logind session. Null when not checked.
  ///
  /// This is the part that catches WSL: an agent can be running and correctly
  /// registered, yet never consulted, because the caller has no session to
  /// map it to.
  final bool? canPrompt;

  /// Extra context for the report, when there is something worth saying.
  final String? detail;

  /// True when an install would proceed without any user interaction.
  bool get isReady => status == AuthStatus.authorized;
}

/// The polkit action `emb deps` needs in order to install host packages.
const packageInstallAction = 'org.freedesktop.packagekit.package-install';

/// Probe whether this caller is authorized to install host packages.
///
/// Deliberately **never** prompts: `pkcheck` is invoked without
/// `--allow-user-interaction`, so running `emb doctor` cannot pop an
/// authentication dialog as a side effect of a diagnostic.
///
/// Returns [AuthStatus.unknown] rather than guessing when the tooling is not
/// present, so a missing `pkcheck` is never reported as a failure.
Future<AuthProbeResult> probeAuthorization(
  HostInfo host, {
  required ProcessRunner runProcess,
}) async {
  if (host.os != HostOs.linux) {
    return const AuthProbeResult(AuthStatus.unknown);
  }

  final canPrompt = await _hasSession(runProcess);

  final RunResult check;
  try {
    check = await runProcess('pkcheck', [
      '--action-id',
      packageInstallAction,
      '--process',
      '$pid',
    ], output: ProcessOutputMode.capture);
  } on ProcessException {
    return const AuthProbeResult(
      AuthStatus.unknown,
      detail: 'pkcheck not found; cannot determine authorization',
    );
  }

  // pkcheck exit codes: 0 authorized, 1 not authorized, 2 authentication
  // required (it declines to prompt because -u was not passed), 3 error.
  switch (check.exitCode) {
    case 0:
      return AuthProbeResult(
        AuthStatus.authorized,
        canPrompt: canPrompt,
        detail: 'no prompt needed',
      );
    case 2:
      return AuthProbeResult(
        AuthStatus.authRequired,
        canPrompt: canPrompt,
        detail: canPrompt == false
            ? 'no login session, so a prompt cannot be shown — '
                  'authorize via a polkit rule or run as root'
            : 'you will be prompted to authenticate',
      );
    case 1:
      return AuthProbeResult(
        AuthStatus.denied,
        canPrompt: canPrompt,
        detail: 'policy refuses this user',
      );
    default:
      return AuthProbeResult(
        AuthStatus.unknown,
        canPrompt: canPrompt,
        detail: 'pkcheck exited ${check.exitCode}',
      );
  }
}

/// Whether this process belongs to a logind session.
///
/// `loginctl session-status` fails when the caller belongs to none, which is
/// the case for tool-spawned shells and is why an agent may never be reached.
Future<bool?> _hasSession(ProcessRunner runProcess) async {
  try {
    final r = await runProcess('loginctl', const [
      'session-status',
    ], output: ProcessOutputMode.capture);
    return r.exitCode == 0;
  } on ProcessException {
    return null;
  }
}
