import 'package:args/command_runner.dart';

/// Reject positional arguments on a command that accepts none.
///
/// `args` ignores unrecognized positionals, so without this a transposed
/// subcommand runs a *different* command and reports a plausible-looking
/// result: `emb sync boards` ran the repository sync and printed
/// "No source repositories found to sync", giving no hint that `boards` had
/// been discarded.
///
/// When the stray argument is itself a command that has this one as a
/// subcommand, the two were almost certainly typed in the wrong order — say
/// so, since that is the whole failure mode this guards.
void rejectPositionals(Command<int> command) {
  final rest = command.argResults?.rest ?? const <String>[];
  if (rest.isEmpty) return;

  final stray = rest.first;
  final runner = command.runner;
  final swapped = runner?.commands[stray];
  final transposed =
      swapped != null && swapped.subcommands.containsKey(command.name);

  throw UsageException(
    '${command.name}: unexpected argument "$stray".'
    '${transposed ? '\nDid you mean `${runner!.executableName} $stray '
              '${command.name}`?' : ''}',
    command.usage,
  );
}
