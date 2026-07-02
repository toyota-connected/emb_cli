import 'package:args/command_runner.dart';
import 'package:emb_cli/src/cache/cache_dir.dart';
import 'package:emb_cli/src/cache/store.dart';
import 'package:emb_cli/src/json_output.dart';
import 'package:mason_logger/mason_logger.dart';

/// {@template cache_command}
/// `emb cache` — inspect and reclaim the shared artifact cache
/// (`$EMB_CACHE_DIR`, else `$XDG_CACHE_HOME/emb`, else `~/.cache/emb`).
/// {@endtemplate}
class CacheCommand extends Command<int> {
  /// {@macro cache_command}
  CacheCommand({required Logger logger, Map<String, String>? environment}) {
    addSubcommand(CachePathCommand(logger: logger, environment: environment));
    addSubcommand(CacheListCommand(logger: logger, environment: environment));
    addSubcommand(CacheGcCommand(logger: logger, environment: environment));
  }

  @override
  String get name => 'cache';

  @override
  String get description => 'Inspect and reclaim the shared artifact cache.';
}

/// `emb cache path` — print the resolved cache directory.
class CachePathCommand extends Command<int> {
  /// Creates the subcommand.
  CachePathCommand({required Logger logger, Map<String, String>? environment})
    : _logger = logger,
      _env = environment;

  final Logger _logger;
  final Map<String, String>? _env;

  @override
  String get name => 'path';

  @override
  String get description => 'Print the resolved cache directory.';

  @override
  int run() {
    _logger.info(resolveCacheDir(environment: _env).path);
    return ExitCode.success.code;
  }
}

/// `emb cache list` — list store entries (kind, key, size, lastUsed, refs).
class CacheListCommand extends Command<int> {
  /// Creates the subcommand.
  CacheListCommand({required Logger logger, Map<String, String>? environment})
    : _logger = logger,
      _env = environment {
    argParser.addFlag(
      'json',
      negatable: false,
      help: 'Emit a machine-readable {schema, command, ok, data} envelope.',
    );
  }

  final Logger _logger;
  final Map<String, String>? _env;

  @override
  String get name => 'list';

  @override
  String get description => 'List cached toolchain/engine store entries.';

  @override
  int run() {
    final store = Store(resolveCacheDir(environment: _env));
    final entries = store.list()
      ..sort((a, b) {
        final k = a.kind.compareTo(b.kind);
        return k != 0 ? k : a.key.compareTo(b.key);
      });

    if (argResults?['json'] == true) {
      _logger.info(
        jsonEnvelope(
          'cache list',
          ok: true,
          data: {
            'entries': [
              for (final e in entries)
                {
                  'kind': e.kind,
                  'key': e.key,
                  'sizeBytes': e.meta?.sizeBytes ?? 0,
                  'lastUsed': e.meta?.lastUsed,
                  'complete': e.meta?.complete ?? false,
                  'refs': e.liveRefs,
                },
            ],
          },
        ),
      );
      return ExitCode.success.code;
    }

    if (entries.isEmpty) {
      _logger.info('Cache is empty.');
      return ExitCode.success.code;
    }
    for (final e in entries) {
      final size = _human(e.meta?.sizeBytes ?? 0);
      final flags = [
        if (!(e.meta?.complete ?? false)) 'incomplete',
        '${e.liveRefs} ref${e.liveRefs == 1 ? "" : "s"}',
      ].join(', ');
      _logger.info('${e.kind}/${e.key}  ($size, $flags)');
    }
    return ExitCode.success.code;
  }
}

/// `emb cache gc` — remove incomplete and unreferenced-and-stale entries.
class CacheGcCommand extends Command<int> {
  /// Creates the subcommand.
  CacheGcCommand({required Logger logger, Map<String, String>? environment})
    : _logger = logger,
      _env = environment {
    argParser.addFlag(
      'dry-run',
      negatable: false,
      help: 'Report what would be removed without deleting anything.',
    );
  }

  final Logger _logger;
  final Map<String, String>? _env;

  @override
  String get name => 'gc';

  @override
  String get description =>
      'Remove incomplete entries and unreferenced, stale entries.';

  @override
  Future<int> run() async {
    final dryRun = argResults?['dry-run'] == true;
    final store = Store(resolveCacheDir(environment: _env));
    final report = await store.gc(dryRun: dryRun);
    if (report.removed.isEmpty) {
      _logger.info('Nothing to reclaim.');
      return ExitCode.success.code;
    }
    for (final r in report.removed) {
      _logger.info('${dryRun ? "would remove" : "removed"} $r');
    }
    _logger.info(
      '${dryRun ? "Would reclaim" : "Reclaimed"} ${_human(report.bytesFreed)} '
      'across ${report.removed.length} entr'
      '${report.removed.length == 1 ? "y" : "ies"}.',
    );
    return ExitCode.success.code;
  }
}

/// A byte count as a short human string (e.g. `1.4 GiB`).
String _human(int bytes) {
  const units = ['B', 'KiB', 'MiB', 'GiB', 'TiB'];
  var size = bytes.toDouble();
  var unit = 0;
  while (size >= 1024 && unit < units.length - 1) {
    size /= 1024;
    unit++;
  }
  final s = unit == 0 ? size.toStringAsFixed(0) : size.toStringAsFixed(1);
  return '$s ${units[unit]}';
}
