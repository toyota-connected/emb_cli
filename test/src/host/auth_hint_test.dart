import 'package:emb_cli/src/host/auth_hint.dart';
import 'package:emb_cli/src/host/host_info.dart';
import 'package:test/test.dart';

HostInfo _host([HostOs os = HostOs.linux]) => HostInfo(
  os: os,
  machineArch: 'x86_64',
  archAliases: const {'x86_64'},
  hostType: 'fedora',
  versionId: '42',
);

void main() {
  group('authFailureHint', () {
    test('is empty off Linux rather than guessing', () {
      for (final os in const [HostOs.macos, HostOs.windows]) {
        expect(authFailureHint(_host(os), interactive: true), isEmpty);
        expect(authFailureHint(_host(os), interactive: false), isEmpty);
      }
    });

    test('interactive blames the missing answer, not the flag', () {
      final text = authFailureHint(_host(), interactive: true).join('\n');
      expect(text, contains('pkttyagent'));
      expect(text, contains('login session'));
      expect(
        text,
        isNot(contains('--no-interactive')),
        reason: 'the operator did not pass it; suggesting it would confuse',
      );
    });

    test('non-interactive says authenticating is not the fix', () {
      final text = authFailureHint(_host(), interactive: false).join('\n');
      expect(text, contains('does not grant authorization'));
      expect(text, contains('--no-interactive'));
      expect(
        text,
        isNot(contains('pkttyagent')),
        reason: 'an agent cannot help when no prompt was ever attempted',
      );
    });

    test('both branches offer the polkit rule', () {
      for (final interactive in const [true, false]) {
        final text = authFailureHint(_host(), interactive: interactive).join();
        expect(text, contains('polkit.addRule'));
        expect(text, contains('49-emb-packagekit.rules'));
      }
    });

    // The rule must stay scoped. A blanket grant on the whole namespace would
    // also cover repo reconfiguration and untrusted-package installs.
    test('the suggested rule is scoped to three named actions', () {
      final text = authFailureHint(_host(), interactive: true).join('\n');
      expect(text, contains('org.freedesktop.packagekit.package-install'));
      expect(text, contains('org.freedesktop.packagekit.package-remove'));
      expect(text, contains('org.freedesktop.packagekit.system-update'));
      expect(
        text,
        isNot(contains('indexOf("org.freedesktop.packagekit.")')),
        reason: 'must not regress to a blanket namespace grant',
      );
    });

    // The admin group differs by distro: wheel on Fedora/RHEL/Arch, sudo on
    // Debian/Ubuntu. A wheel-only rule silently does nothing on Debian, which
    // is the harder failure to diagnose because the rule looks installed.
    test('the rule covers both admin group conventions', () {
      final text = authFailureHint(_host(), interactive: true).join('\n');
      expect(text, contains('isInGroup("wheel")'));
      expect(text, contains('isInGroup("sudo")'));
    });

    test('states the tradeoff rather than just handing over a rule', () {
      final text = authFailureHint(_host(), interactive: true).join('\n');
      expect(text, contains('wheel'));
      expect(text, contains('persistent'));
    });
  });
}
