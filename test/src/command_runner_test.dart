import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:cli_completion/cli_completion.dart';
import 'package:emb_cli/src/command_runner.dart';
import 'package:emb_cli/src/verbosity.dart';
import 'package:emb_cli/src/version.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:mocktail/mocktail.dart';
import 'package:pub_updater/pub_updater.dart';
import 'package:test/test.dart';

class _MockLogger extends Mock implements Logger {}

class _MockProgress extends Mock implements Progress {}

class _MockPubUpdater extends Mock implements PubUpdater {}

// Deliberately far ahead of any real packageVersion. It used to be '0.0.0',
// which is *older* than what emb ships -- the "shows update message when newer
// version exists" test passed only because the check compared for inequality
// rather than ordering, so it asserted the bug rather than the behavior.
const latestVersion = '99.9.9';

/// An older published version: an unreleased build is ahead of pub.dev, which
/// is every developer on main and every release branch before its publish.
const olderVersion = '0.0.1';

final updatePrompt =
    '''
${lightYellow.wrap('Update available!')} ${lightCyan.wrap(packageVersion)} \u2192 ${lightCyan.wrap(latestVersion)}
Run ${lightCyan.wrap('$executableName update')} to update''';

void main() {
  group('EmbCliCommandRunner', () {
    late PubUpdater pubUpdater;
    late Logger logger;
    late EmbCliCommandRunner commandRunner;

    setUp(() {
      pubUpdater = _MockPubUpdater();

      when(
        () => pubUpdater.getLatestVersion(any()),
      ).thenAnswer((_) async => packageVersion);

      logger = _MockLogger();

      commandRunner = EmbCliCommandRunner(
        logger: logger,
        pubUpdater: pubUpdater,
      );
    });

    test('does not auto-install shell completion', () {
      // Auto-install writes to $XDG_CONFIG_HOME and can fail noisily on an
      // unrelated command; users opt in explicitly instead.
      expect(commandRunner.enableAutoInstall, isFalse);
    });

    test('shows update message when newer version exists', () async {
      when(
        () => pubUpdater.getLatestVersion(any()),
      ).thenAnswer((_) async => latestVersion);

      final result = await commandRunner.run(['--version']);
      expect(result, equals(ExitCode.success.code));
      verify(() => logger.info(updatePrompt)).called(1);
    });

    // Regression guard: an unreleased build is *ahead* of pub.dev, so telling
    // the user to "update" to the older published version is backwards. This
    // is what CI hit on the 0.2.0 release branch.
    test('does not offer an update to an older published version', () async {
      when(
        () => pubUpdater.getLatestVersion(any()),
      ).thenAnswer((_) async => olderVersion);

      final result = await commandRunner.run(['--version']);
      expect(result, equals(ExitCode.success.code));
      verifyNever(() => logger.info(any(that: contains('Update available'))));
    });

    // The notice goes to stdout, so under --json it lands after the envelope
    // and makes the output unparseable for exactly the callers who asked for
    // machine-readable output.
    test('does not print the update notice under --json', () async {
      when(
        () => pubUpdater.getLatestVersion(any()),
      ).thenAnswer((_) async => latestVersion);

      await commandRunner.run(['doctor', '--json']);
      verifyNever(() => logger.info(updatePrompt));
    });

    test('Does not show update message when the shell calls the '
        'completion command', () async {
      when(
        () => pubUpdater.getLatestVersion(any()),
      ).thenAnswer((_) async => latestVersion);

      final result = await commandRunner.run(['completion']);
      expect(result, equals(ExitCode.success.code));
      verifyNever(() => logger.info(updatePrompt));
    });

    test('does not show update message when using update command', () async {
      when(
        () => pubUpdater.getLatestVersion(any()),
      ).thenAnswer((_) async => latestVersion);
      when(
        () => pubUpdater.update(
          packageName: packageName,
          versionConstraint: any(named: 'versionConstraint'),
        ),
      ).thenAnswer(
        (_) async => ProcessResult(0, ExitCode.success.code, null, null),
      );
      when(
        () => pubUpdater.isUpToDate(
          packageName: any(named: 'packageName'),
          currentVersion: any(named: 'currentVersion'),
        ),
      ).thenAnswer((_) async => true);

      final progress = _MockProgress();
      final progressLogs = <String>[];
      when(() => progress.complete(any())).thenAnswer((answer) {
        final message = answer.positionalArguments.elementAt(0) as String?;
        if (message != null) progressLogs.add(message);
      });
      when(() => logger.progress(any())).thenReturn(progress);

      final result = await commandRunner.run(['update']);
      expect(result, equals(ExitCode.success.code));
      verifyNever(() => logger.info(updatePrompt));
    });

    test(
      'can be instantiated without an explicit analytics/logger instance',
      () {
        final commandRunner = EmbCliCommandRunner();
        expect(commandRunner, isNotNull);
        expect(commandRunner, isA<CompletionCommandRunner<int>>());
      },
    );

    test('handles FormatException', () async {
      const exception = FormatException('oops!');
      var isFirstInvocation = true;
      when(() => logger.info(any())).thenAnswer((_) {
        if (isFirstInvocation) {
          isFirstInvocation = false;
          throw exception;
        }
      });
      final result = await commandRunner.run(['--version']);
      expect(result, equals(ExitCode.usage.code));
      verify(() => logger.err(exception.message)).called(1);
      verify(() => logger.info(commandRunner.usage)).called(1);
    });

    test('handles UsageException', () async {
      final exception = UsageException('oops!', 'exception usage');
      var isFirstInvocation = true;
      when(() => logger.info(any())).thenAnswer((_) {
        if (isFirstInvocation) {
          isFirstInvocation = false;
          throw exception;
        }
      });
      final result = await commandRunner.run(['--version']);
      expect(result, equals(ExitCode.usage.code));
      verify(() => logger.err(exception.message)).called(1);
      verify(() => logger.info('exception usage')).called(1);
    });

    group('--version', () {
      test('outputs current version', () async {
        final result = await commandRunner.run(['--version']);
        expect(result, equals(ExitCode.success.code));
        verify(() => logger.info(packageVersion)).called(1);
      });
    });

    group('verbosity', () {
      tearDown(() => embVerbosity = Verbosity.normal);

      test('-vv enables diagnostic (detail) logging', () async {
        final result = await commandRunner.run(['-vv']);
        expect(result, equals(ExitCode.success.code));
        expect(embVerbosity, Verbosity.debug);
        verify(() => logger.level = Level.verbose).called(1);
        verify(() => logger.detail('Argument information:')).called(1);
        verify(() => logger.detail('  Top level options:')).called(1);
        verifyNever(() => logger.detail('    Command options:'));
      });

      test('-vv dumps sub command options', () async {
        final progress = _MockProgress();
        when(() => logger.progress(any())).thenReturn(progress);

        final result = await commandRunner.run(['-vv', 'update']);
        expect(result, equals(ExitCode.success.code));
        verify(() => logger.detail('  Command: update')).called(1);
        verify(() => logger.detail('    Command options:')).called(1);
      });

      test('-v selects verbose (streaming) at info level', () async {
        final result = await commandRunner.run(['-v']);
        expect(result, equals(ExitCode.success.code));
        expect(embVerbosity, Verbosity.verbose);
        // info level (not Level.verbose) — a single -v streams toolchain
        // output but does not unlock the diagnostic argv/env dumps.
        verify(() => logger.level = Level.info).called(1);
      });

      test('-q selects quiet (errors only)', () async {
        final result = await commandRunner.run(['-q']);
        expect(result, equals(ExitCode.success.code));
        expect(embVerbosity, Verbosity.quiet);
        verify(() => logger.level = Level.error).called(1);
      });
    });
  });
}
