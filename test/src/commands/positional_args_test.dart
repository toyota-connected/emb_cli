import 'package:emb_cli/src/command_runner.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';

class _MockLogger extends Mock implements Logger {}

class _MockProgress extends Mock implements Progress {}

void main() {
  late Logger logger;
  final errors = <String>[];

  setUp(() {
    logger = _MockLogger();
    errors.clear();
    when(() => logger.progress(any())).thenReturn(_MockProgress());
    when(() => logger.err(any())).thenAnswer((i) {
      errors.add('${i.positionalArguments.first}');
    });
  });

  Future<int?> run(List<String> args) =>
      EmbCliCommandRunner(logger: logger).run(args);

  group('commands that take no positionals', () {
    // The reported case: `args` silently discards the stray token, so this ran
    // the repository sync and reported "No source repositories found to sync"
    // -- a plausible-looking result for a command the user never asked for.
    test('a transposed subcommand is caught and corrected', () async {
      final code = await run(['sync', 'boards']);
      expect(code, ExitCode.usage.code);
      final out = errors.join('\n');
      expect(out, contains('unexpected argument "boards"'));
      expect(
        out,
        contains('emb boards sync'),
        reason: 'the transposition is the whole failure mode being guarded',
      );
    });

    test('a stray argument is rejected without a bogus suggestion', () async {
      final code = await run(['deps', 'nonsense']);
      expect(code, ExitCode.usage.code);
      final out = errors.join('\n');
      expect(out, contains('unexpected argument "nonsense"'));
      expect(
        out,
        isNot(contains('Did you mean')),
        reason: 'nonsense is not a command, so there is nothing to suggest',
      );
    });

    test('every guarded command rejects a stray positional', () async {
      for (final name in const [
        'aot',
        'bundle',
        'deps',
        'engine',
        'env',
        'flutter',
        'setup',
        'sync',
        'update',
      ]) {
        errors.clear();
        final code = await run([name, 'stray-token']);
        expect(
          code,
          ExitCode.usage.code,
          reason: '$name should reject an unexpected positional',
        );
        expect(errors.join('\n'), contains('stray-token'));
      }
    });
  });

  group('commands that do take positionals', () {
    // These read argResults.rest for a path; guarding them would break them.
    test('cross consumes its path rather than rejecting it', () async {
      // `cross` still fails here -- the directory does not exist -- so the
      // exit code alone proves nothing. What matters is *why* it failed: the
      // path must be consumed as input, not reported as an unexpected token.
      await run(['cross', 'no-such-dir', '--list-targets']);
      expect(errors.join('\n'), isNot(contains('unexpected argument')));
    });
  });
}
