import 'package:emb_cli/src/step_reporter.dart';
import 'package:emb_cli/src/verbosity.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';

class _MockLogger extends Mock implements Logger {}

class _MockProgress extends Mock implements Progress {}

void main() {
  test('draws an animated spinner at normal verbosity', () {
    final logger = _MockLogger();
    final progress = _MockProgress();
    when(() => logger.progress(any())).thenReturn(progress);

    StepReporter(
      logger,
      verbosity: Verbosity.normal,
    ).start('build').complete('done');

    verify(() => logger.progress('build')).called(1);
    verify(() => progress.complete('done')).called(1);
  });

  test('uses plain banners at -v so streamed output is not garbled', () {
    final logger = _MockLogger();

    StepReporter(
      logger,
      verbosity: Verbosity.verbose,
    ).start('build').complete('done');

    // No spinner (which would rewrite the line and clash with streaming).
    verifyNever(() => logger.progress(any()));
    verify(() => logger.info('▶ build')).called(1);
    verify(() => logger.info(any(that: startsWith('✓ done')))).called(1);
  });

  test('plain failure banner goes to err', () {
    final logger = _MockLogger();

    StepReporter(
      logger,
      verbosity: Verbosity.verbose,
    ).start('build').fail('boom');

    verify(() => logger.err(any(that: startsWith('✗ boom')))).called(1);
  });
}
