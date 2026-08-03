import 'package:emb_cli/src/host/host_info.dart';

/// Remediation lines for an authorization failure from the host package
/// backend, keyed off the mode the run was actually in.
///
/// The daemon reports the same not-authorized error whether it could not
/// prompt or prompted and was refused, so the error text cannot distinguish
/// the two. [interactive] can, because it is what the operator chose, and it
/// decides which advice is useful:
///
/// * interactive — a prompt was permitted but nothing answered it, so the
///   likely gaps are an agent or a usable login session.
/// * non-interactive — no prompt was ever possible, so authenticating is not
///   the fix; the caller must already be authorized.
///
/// Returns an empty list for hosts where this does not apply (macOS and
/// Windows authorize differently), so the caller emits nothing rather than
/// guessing.
List<String> authFailureHint(HostInfo host, {required bool interactive}) {
  if (host.os != HostOs.linux) return const [];
  return [
    ...(interactive ? _interactiveLines : _nonInteractiveLines),
    '',
    'To authorize without a prompt, install a polkit rule:',
    '',
    ..._ruleLines,
    '',
    'That grants unattended install/remove/update to everyone in wheel,',
    'with no authentication — a persistent change to system policy. It is',
    'scoped to three actions rather than all of',
    'org.freedesktop.packagekit.* on purpose.',
  ];
}

const _interactiveLines = <String>[
  'The package manager was allowed to ask you to authenticate, but no',
  'answer arrived. Usually one of:',
  '',
  '  • No authentication agent is running. In a terminal session:',
  r'      pkttyagent --process $$ &',
  '',
  '  • This shell has no login session, so an agent can never be reached.',
  '    Check with:',
  '      loginctl session-status',
  '    A usable session reports your own uid, Service=login and',
  '    Class=user. Under WSL this often fails; use the rule below.',
];

const _nonInteractiveLines = <String>[
  'Running non-interactively, so no authentication was attempted.',
  'Non-interactive suppresses the prompt; it does not grant authorization.',
  '',
  'Either drop --no-interactive so you can authenticate, or authorize',
  'ahead of time.',
];

const _ruleLines = <String>[
  '  # /etc/polkit-1/rules.d/49-emb-packagekit.rules',
  '  polkit.addRule(function(action, subject) {',
  '      var allowed = [',
  '          "org.freedesktop.packagekit.package-install",',
  '          "org.freedesktop.packagekit.package-remove",',
  '          "org.freedesktop.packagekit.system-update"',
  '      ];',
  '      if (allowed.indexOf(action.id) !== -1 &&',
  '          subject.isInGroup("wheel")) {',
  '          return polkit.Result.YES;',
  '      }',
  '  });',
];
