import 'package:emb_cli/src/host/interactivity.dart';
import 'package:test/test.dart';

void main() {
  group('Interactivity.resolve', () {
    test('defaults to interactive with an empty environment', () {
      final r = Interactivity.resolve(environment: const {});
      expect(r.interactive, isTrue);
      expect(r.source, InteractivitySource.fallback);
    });

    test('EMB_NON_INTERACTIVE=1 opts out', () {
      final r = Interactivity.resolve(
        environment: const {'EMB_NON_INTERACTIVE': '1'},
      );
      expect(r.interactive, isFalse);
      expect(r.source, InteractivitySource.environment);
    });

    test('--no-interactive wins over the environment', () {
      final r = Interactivity.resolve(
        explicit: false,
        environment: const {'EMB_NON_INTERACTIVE': '1'},
      );
      expect(r.interactive, isFalse);
      expect(r.source, InteractivitySource.flag);
    });

    test('--interactive overrides EMB_NON_INTERACTIVE', () {
      final r = Interactivity.resolve(
        explicit: true,
        environment: const {'EMB_NON_INTERACTIVE': '1'},
      );
      expect(r.interactive, isTrue, reason: 'flag outranks environment');
      expect(r.source, InteractivitySource.flag);
    });

    // Regression guard: an earlier revision auto-detected CI and flipped the
    // default. Environment sniffing makes the mode depend on ambient state the
    // operator cannot see in the command they typed. See plan DR-2.
    test('CI-ish variables alone do NOT flip the default', () {
      for (final key in const [
        'CI',
        'GITHUB_ACTIONS',
        'GITLAB_CI',
        'JENKINS_URL',
        'BUILDKITE',
      ]) {
        final r = Interactivity.resolve(environment: {key: 'true'});
        expect(
          r.interactive,
          isTrue,
          reason: '$key must not imply non-interactive',
        );
        expect(r.source, InteractivitySource.fallback);
      }
    });

    // TTY absence is a signal for emb's own confirm prompt, never for the
    // daemon hint: an agent can exist with no controlling TTY. See plan DR-3.
    test('no TTY-derived input is consulted', () {
      final r = Interactivity.resolve(environment: const {'TERM': 'dumb'});
      expect(r.interactive, isTrue);
    });

    group('environment value parsing', () {
      for (final entry in const {
        '1': false,
        'true': false,
        'yes': false,
        'TRUE': false,
        '': true,
        '0': true,
        'false': true,
        'False': true,
        '  ': true,
      }.entries) {
        test('"${entry.key}" -> interactive=${entry.value}', () {
          final r = Interactivity.resolve(
            environment: {'EMB_NON_INTERACTIVE': entry.key},
          );
          expect(r.interactive, entry.value);
        });
      }
    });
  });

  group('describe', () {
    test('names the flag as the source', () {
      final off = Interactivity.resolve(explicit: false, environment: const {});
      expect(off.describe(), 'non-interactive (--no-interactive)');
      final on = Interactivity.resolve(explicit: true, environment: const {});
      expect(on.describe(), 'interactive (--interactive)');
    });

    test('names the environment variable as the source', () {
      expect(
        Interactivity.resolve(
          environment: const {'EMB_NON_INTERACTIVE': '1'},
        ).describe(),
        'non-interactive (EMB_NON_INTERACTIVE)',
      );
    });

    test('names the default', () {
      expect(
        Interactivity.resolve(environment: const {}).describe(),
        'interactive (default)',
      );
    });
  });
}
