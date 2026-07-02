import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:emb_cli/src/cache/cache_dir.dart';
import 'package:emb_cli/src/cache/store.dart';
import 'package:emb_cli/src/engine/engine_artifacts.dart';
import 'package:emb_cli/src/json_output.dart';
import 'package:emb_cli/src/workspace/workspace.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:path/path.dart' as p;

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
    addSubcommand(
      CacheMigrateCommand(logger: logger, environment: environment),
    );
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

/// `emb cache migrate` — adopt a workspace's existing, un-migrated toolchain
/// and engine trees into the shared store (moved in place of a re-download),
/// leaving symlinks behind.
class CacheMigrateCommand extends Command<int> {
  /// Creates the subcommand.
  CacheMigrateCommand({
    required Logger logger,
    Map<String, String>? environment,
  }) : _logger = logger,
       _env = environment {
    argParser
      ..addOption(
        'workspace',
        abbr: 'w',
        help: r'Workspace to migrate (defaults to $FLUTTER_WORKSPACE or cwd).',
      )
      ..addFlag(
        'dry-run',
        negatable: false,
        help: 'Report what would be adopted without moving anything.',
      );
  }

  final Logger _logger;
  final Map<String, String>? _env;

  @override
  String get name => 'migrate';

  @override
  String get description =>
      "Adopt a workspace's existing toolchain/engine trees into the store.";

  @override
  Future<int> run() async {
    final dryRun = argResults?['dry-run'] == true;
    final ws = Workspace.resolve(override: argResults?['workspace'] as String?);
    final store = Store(resolveCacheDir(environment: _env));
    // The `.config/flutter_workspace/<id>` dir holding the per-workspace trees.
    final fw = Directory(p.dirname(ws.platformDir('_').path));
    if (!fw.existsSync()) {
      _logger.info('No workspace artifacts to migrate (${fw.path} absent).');
      return ExitCode.success.code;
    }

    final adopted = <String>[];
    var bytes = 0;
    for (final dir in fw.listSync().whereType<Directory>()) {
      final id = p.basename(dir.path);
      if (id.startsWith('cross-')) {
        // cross-<triple>-<sysrootKey>/toolchain/<dirName> → kind:toolchain.
        final tc = Directory(p.join(dir.path, 'toolchain'));
        if (tc.existsSync()) {
          for (final e in tc.listSync().whereType<Directory>()) {
            bytes += await _adopt(
              store,
              'toolchain',
              p.basename(e.path),
              e,
              dryRun: dryRun,
              adopted: adopted,
            );
          }
        }
      } else if (id == 'flutter-engine') {
        // flutter-engine/<commit>/engine-sdk-<runtime>-<arch> → kind:engine.
        for (final commitDir in dir.listSync().whereType<Directory>()) {
          final commit = p.basename(commitDir.path);
          for (final e in commitDir.listSync().whereType<Directory>()) {
            final b = p.basename(e.path);
            const prefix = 'engine-sdk-';
            if (!b.startsWith(prefix)) continue;
            final rest = b.substring(prefix.length); // <runtime>-<arch>
            final dash = rest.indexOf('-');
            if (dash < 0) continue;
            final runtime = rest.substring(0, dash);
            final arch = EngineArtifacts.engineArch(rest.substring(dash + 1));
            bytes += await _adopt(
              store,
              'engine',
              '$commit-$arch-$runtime',
              e,
              dryRun: dryRun,
              adopted: adopted,
            );
          }
        }
      }
    }

    if (adopted.isEmpty) {
      _logger.info('Nothing to migrate (already store-backed).');
      return ExitCode.success.code;
    }
    for (final a in adopted) {
      _logger.info('${dryRun ? "would adopt" : "adopted"} $a');
    }
    _logger.info(
      '${dryRun ? "Would move" : "Moved"} ${_human(bytes)} into the store '
      'across ${adopted.length} entr${adopted.length == 1 ? "y" : "ies"}.',
    );
    return ExitCode.success.code;
  }

  /// Adopt [dir] into the store as ([kind], [key]) and symlink it back. A
  /// symlink (already migrated) is skipped. Returns the bytes moved.
  Future<int> _adopt(
    Store store,
    String kind,
    String key,
    Directory dir, {
    required bool dryRun,
    required List<String> adopted,
  }) async {
    if (FileSystemEntity.isLinkSync(dir.path)) return 0;
    final size = _treeSize(dir);
    if (!dryRun) {
      await store.adopt(kind: kind, key: key, existingDir: dir);
      store.materialize(kind: kind, key: key, linkPath: dir.path);
    }
    adopted.add('$kind/$key');
    return size;
  }
}

/// Total size of the files under [d] (for migrate's byte report).
int _treeSize(Directory d) {
  if (!d.existsSync()) return 0;
  var n = 0;
  for (final e in d.listSync(recursive: true, followLinks: false)) {
    if (e is File) {
      try {
        n += e.lengthSync();
      } on Object {
        // Unreadable entry — skip.
      }
    }
  }
  return n;
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
