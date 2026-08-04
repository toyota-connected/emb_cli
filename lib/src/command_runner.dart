import 'dart:io';

import 'package:args/args.dart';
import 'package:args/command_runner.dart';
import 'package:cli_completion/cli_completion.dart';
import 'package:emb_cli/src/commands/commands.dart';
import 'package:emb_cli/src/verbosity.dart';
import 'package:emb_cli/src/version.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:pub_semver/pub_semver.dart';
import 'package:pub_updater/pub_updater.dart';

const executableName = 'emb';
const packageName = 'emb_cli';
const description = 'Flutter Embedder CLI Tool';

/// {@template emb_cli_command_runner}
/// A [CommandRunner] for the CLI.
///
/// ```bash
/// $ emb --version
/// ```
/// {@endtemplate}
class EmbCliCommandRunner extends CompletionCommandRunner<int> {
  /// {@macro emb_cli_command_runner}
  EmbCliCommandRunner({Logger? logger, PubUpdater? pubUpdater})
    : _logger = logger ?? Logger(),
      _pubUpdater = pubUpdater ?? PubUpdater(),
      super(executableName, description) {
    // Add root options and flags
    argParser
      ..addFlag('version', negatable: false, help: 'Print the current version.')
      ..addFlag(
        'verbose',
        abbr: 'v',
        negatable: false,
        help:
            'Stream toolchain output live; repeat (-vv) for diagnostic '
            'logging (all shell commands, resolved env).',
      )
      ..addFlag(
        'quiet',
        abbr: 'q',
        negatable: false,
        help: 'Errors only; suppress progress and info logging.',
      );

    // Add sub commands
    addCommand(SetupCommand(logger: _logger));
    addCommand(DoctorCommand(logger: _logger));
    addCommand(DepsCommand(logger: _logger));
    addCommand(SyncCommand(logger: _logger));
    addCommand(FlutterCommand(logger: _logger));
    addCommand(EngineCommand(logger: _logger));
    addCommand(AotCommand(logger: _logger));
    addCommand(BundleCommand(logger: _logger));
    addCommand(BuildCommand(logger: _logger));
    addCommand(CrossCommand(logger: _logger));
    addCommand(FetchCommand(logger: _logger));
    addCommand(CacheCommand(logger: _logger));
    addCommand(BoardsCommand(logger: _logger));
    addCommand(MatrixCommand(logger: _logger));
    addCommand(EnvCommand(logger: _logger));
    addCommand(UpdateCommand(logger: _logger, pubUpdater: _pubUpdater));
  }

  @override
  void printUsage() => _logger.info(usage);

  // Don't write shell-completion files on every invocation. The auto-installer
  // targets $XDG_CONFIG_HOME, which a workspace setup_env.sh can point into the
  // build tree (a fragile, sometimes non-directory path) — failing noisily on
  // an unrelated command. Users opt in with `emb install-completion-files`.
  @override
  bool get enableAutoInstall => false;

  final Logger _logger;
  final PubUpdater _pubUpdater;

  @override
  Future<int> run(Iterable<String> args) async {
    // `package:args` can't count repeated flags, so resolve verbosity in a raw
    // pre-pass (-v, -vv, --verbose, -q, --quiet, else $EMB_VERBOSITY) and strip
    // those tokens before parsing. The level drives both mason logging and the
    // process runner's streaming (see `embVerbosity`).
    final (verbosity, rest) = _resolveVerbosity(args.toList());
    embVerbosity = verbosity;
    _logger.level = _levelFor(verbosity);
    try {
      final topLevelResults = parse(rest);
      return await runCommand(topLevelResults) ?? ExitCode.success.code;
    } on FormatException catch (e, stackTrace) {
      // On format errors, show the commands error message, root usage and
      // exit with an error code
      _logger
        ..err(e.message)
        ..err('$stackTrace')
        ..info('')
        ..info(usage);
      return ExitCode.usage.code;
    } on UsageException catch (e) {
      // On usage errors, show the commands usage message and
      // exit with an error code
      _logger
        ..err(e.message)
        ..info('')
        ..info(e.usage);
      return ExitCode.usage.code;
    }
  }

  /// Counts `-v`/`-vv`/`--verbose` and `-q`/`--quiet` occurrences, strips them,
  /// and returns the resolved [Verbosity] plus the remaining args. When no
  /// verbosity flag is present, `$EMB_VERBOSITY` (`0`|`1`|`2`) is honored.
  (Verbosity, List<String>) _resolveVerbosity(List<String> args) {
    var vCount = 0;
    var quiet = false;
    final rest = <String>[];
    final shortV = RegExp(r'^-(v+)$');
    for (final a in args) {
      if (a == '--verbose') {
        vCount++;
        continue;
      }
      if (a == '--quiet' || a == '-q') {
        quiet = true;
        continue;
      }
      final m = shortV.firstMatch(a);
      if (m != null) {
        vCount += m.group(1)!.length;
        continue;
      }
      rest.add(a);
    }
    if (vCount == 0 && !quiet) {
      final env = int.tryParse(Platform.environment['EMB_VERBOSITY'] ?? '');
      if (env != null) {
        return (
          switch (env) {
            <= 0 => Verbosity.normal,
            1 => Verbosity.verbose,
            _ => Verbosity.debug,
          },
          rest,
        );
      }
    }
    if (quiet) return (Verbosity.quiet, rest);
    return (
      switch (vCount) {
        0 => Verbosity.normal,
        1 => Verbosity.verbose,
        _ => Verbosity.debug,
      },
      rest,
    );
  }

  /// Maps [Verbosity] to a mason [Level]. `verbose` stays at `info` (streaming
  /// is a runner concern, not a logging one); only `-vv` unlocks `detail(...)`.
  Level _levelFor(Verbosity v) => switch (v) {
    Verbosity.quiet => Level.error,
    Verbosity.normal => Level.info,
    Verbosity.verbose => Level.info,
    Verbosity.debug => Level.verbose,
  };

  @override
  Future<int?> runCommand(ArgResults topLevelResults) async {
    // Fast track completion command
    if (topLevelResults.command?.name == 'completion') {
      await super.runCommand(topLevelResults);
      return ExitCode.success.code;
    }

    // Verbose logs
    _logger
      ..detail('Argument information:')
      ..detail('  Top level options:');
    for (final option in topLevelResults.options) {
      if (topLevelResults.wasParsed(option)) {
        _logger.detail('  - $option: ${topLevelResults[option]}');
      }
    }
    if (topLevelResults.command != null) {
      final commandResult = topLevelResults.command!;
      _logger
        ..detail('  Command: ${commandResult.name}')
        ..detail('    Command options:');
      for (final option in commandResult.options) {
        if (commandResult.wasParsed(option)) {
          _logger.detail('    - $option: ${commandResult[option]}');
        }
      }
    }

    // Run the command or show version
    final int? exitCode;
    if (topLevelResults['version'] == true) {
      _logger.info(packageVersion);
      exitCode = ExitCode.success.code;
    } else {
      exitCode = await super.runCommand(topLevelResults);
    }

    // Check for updates. Never under `--json`: the notice is written to
    // stdout, so it would land after the envelope and make the output
    // unparseable for exactly the callers who asked for machine-readable
    // output.
    final sub = topLevelResults.command;
    final wantsJson =
        sub != null && sub.options.contains('json') && sub['json'] == true;
    if (sub?.name != UpdateCommand.commandName && !wantsJson) {
      await _checkForUpdates();
    }

    return exitCode;
  }

  /// Checks if the current version (set by the build runner on the
  /// version.dart file) is the most recent one. If not, show a prompt to the
  /// user.
  Future<void> _checkForUpdates() async {
    try {
      final latestVersion = await _pubUpdater.getLatestVersion(packageName);
      // Only a *newer* published version is an update. Comparing for equality
      // told anyone running an unreleased build to "update" to the older
      // published one — which is every developer on main, and every release
      // branch between the version bump and the publish.
      if (Version.parse(latestVersion) > Version.parse(packageVersion)) {
        _logger
          ..info('')
          ..info('''
${lightYellow.wrap('Update available!')} ${lightCyan.wrap(packageVersion)} \u2192 ${lightCyan.wrap(latestVersion)}
Run ${lightCyan.wrap('$executableName update')} to update''');
      }
    } catch (_) {}
  }
}
