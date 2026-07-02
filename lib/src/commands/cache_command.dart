import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:emb_cli/src/cache/cache_dir.dart';
import 'package:emb_cli/src/cache/oci_transport.dart';
import 'package:emb_cli/src/cache/store.dart';
import 'package:emb_cli/src/cross/process_runner.dart';
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
    addSubcommand(CachePushCommand(logger: logger, environment: environment));
    addSubcommand(CachePullCommand(logger: logger, environment: environment));
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

/// Shared base for `cache push`/`pull`: registry/repo resolution and the store.
abstract class _CacheOciCommand extends Command<int> {
  _CacheOciCommand({
    required Logger logger,
    Map<String, String>? environment,
    ProcessRunner? run,
    OciTransport? transport,
  }) : _logger = logger,
       _env = environment,
       _run = run ?? defaultProcessRunner,
       _transport = transport {
    argParser
      ..addOption(
        'registry',
        help: r'Registry host[/path] (else $EMB_CACHE_REGISTRY).',
      )
      ..addOption(
        'repo',
        defaultsTo: 'emb-cache',
        help: 'Repository name under the registry.',
      )
      ..addFlag(
        'json',
        negatable: false,
        help: 'Emit a machine-readable {schema, command, ok, data} envelope.',
      );
  }

  final Logger _logger;
  final Map<String, String>? _env;
  final ProcessRunner _run;
  final OciTransport? _transport;

  OciTransport get transport => _transport ?? OrasTransport(run: _run);
  Store store() => Store(resolveCacheDir(environment: _env), run: _run);

  /// The `<registry>` to use, or null (with an error logged) when unresolved.
  String? registry() {
    final r =
        (argResults?['registry'] as String?) ?? _env?['EMB_CACHE_REGISTRY'];
    if (r == null || r.isEmpty) {
      _logger.err(
        'No registry. Pass --registry <host>[/path] or set '
        r'$EMB_CACHE_REGISTRY.',
      );
      return null;
    }
    return r;
  }

  String get repo => argResults?['repo'] as String;
  bool get json => argResults?['json'] == true;

  /// Parse `<kind>/<key>` selectors from the positional args (split on the
  /// first `/`). Returns null (error logged) on a malformed selector.
  List<(String, String)>? selectors() {
    final out = <(String, String)>[];
    for (final a in argResults?.rest ?? const <String>[]) {
      final slash = a.indexOf('/');
      if (slash <= 0 || slash == a.length - 1) {
        _logger.err('Bad selector "$a": expected <kind>/<key>.');
        return null;
      }
      out.add((a.substring(0, slash), a.substring(slash + 1)));
    }
    return out;
  }
}

/// `emb cache push` — upload store entries to an OCI registry as artifacts.
class CachePushCommand extends _CacheOciCommand {
  /// Creates the subcommand.
  CachePushCommand({
    required super.logger,
    super.environment,
    super.run,
    super.transport,
  }) {
    argParser
      ..addFlag(
        'force',
        negatable: false,
        help: 'Push even if the ref already exists (default: skip).',
      )
      ..addFlag(
        'dry-run',
        negatable: false,
        help: 'Report the refs that would be pushed without uploading.',
      );
  }

  @override
  String get name => 'push';

  @override
  String get description =>
      'Push cached store entries to an OCI registry (via oras).';

  @override
  Future<int> run() async {
    final registry = this.registry();
    if (registry == null) return ExitCode.usage.code;
    final sel = selectors();
    if (sel == null) return ExitCode.usage.code;
    final dryRun = argResults?['dry-run'] == true;
    final force = argResults?['force'] == true;
    final st = store();

    // Complete entries only; filter to the named selectors when given.
    var entries = st.list().where((e) => e.meta?.complete ?? false).toList();
    if (sel.isNotEmpty) {
      final want = sel.toSet();
      entries = entries.where((e) => want.contains((e.kind, e.key))).toList();
    }
    if (entries.isEmpty) {
      _logger.info(
        json
            ? jsonEnvelope('cache push', ok: true, data: {'pushed': <String>[]})
            : 'Nothing to push.',
      );
      return ExitCode.success.code;
    }

    final pushed = <String>[];
    final skipped = <String>[];
    for (final e in entries) {
      final ref = cacheRef(registry, repo, e.kind, e.key);
      if (dryRun) {
        pushed.add(ref);
        if (!json) _logger.info('would push $ref');
        continue;
      }
      if (!force && await transport.exists(ref)) {
        skipped.add(ref);
        if (!json) _logger.info('skip (exists) $ref');
        continue;
      }
      final tmp = Directory.systemTemp.createTempSync('emb_push_');
      try {
        final layer = File(
          p.join(tmp.path, '${cacheTag(e.kind, e.key)}.tar.gz'),
        );
        final root = st.rootOf(e.kind, e.key);
        final tar = await _run('tar', [
          '-czf',
          layer.path,
          '-C',
          root.path,
          '.',
        ], output: ProcessOutputMode.capture);
        if (tar.exitCode != 0) {
          _logger.err('tar ${e.kind}/${e.key} failed: ${tar.stderr}');
          return ExitCode.software.code;
        }
        try {
          await transport.push(
            ref,
            layer,
            annotations: {
              'org.opencontainers.image.title': p.basename(layer.path),
              'dev.emb.cache.kind': e.kind,
              'dev.emb.cache.key': e.key,
              if (e.meta?.sourceUrl case final u?) 'dev.emb.cache.source': u,
              if (e.meta?.sizeBytes case final s?) 'dev.emb.cache.size': '$s',
            },
          );
        } on OciTransportException catch (err) {
          _logger.err(err.message);
          return ExitCode.software.code;
        }
        pushed.add(ref);
        if (!json) _logger.info('pushed $ref');
      } finally {
        tmp.deleteSync(recursive: true);
      }
    }

    if (json) {
      _logger.info(
        jsonEnvelope(
          'cache push',
          ok: true,
          data: {'pushed': pushed, 'skipped': skipped, 'dryRun': dryRun},
        ),
      );
    } else {
      _logger.info(
        '${dryRun ? "Would push" : "Pushed"} ${pushed.length}, '
        'skipped ${skipped.length}.',
      );
    }
    return ExitCode.success.code;
  }
}

/// `emb cache pull` — download store entries from an OCI registry.
class CachePullCommand extends _CacheOciCommand {
  /// Creates the subcommand.
  CachePullCommand({
    required super.logger,
    super.environment,
    super.run,
    super.transport,
  }) {
    argParser.addOption(
      'link',
      help: 'Symlink each pulled entry into this directory (materialize).',
    );
  }

  @override
  String get name => 'pull';

  @override
  String get description =>
      'Pull store entries from an OCI registry into the cache (via oras).';

  @override
  Future<int> run() async {
    final registry = this.registry();
    if (registry == null) return ExitCode.usage.code;
    final sel = selectors();
    if (sel == null) return ExitCode.usage.code;
    if (sel.isEmpty) {
      _logger.err('Nothing to pull: name one or more <kind>/<key> entries.');
      return ExitCode.usage.code;
    }
    final st = store();
    final link = argResults?['link'] as String?;

    final pulled = <String>[];
    for (final (kind, key) in sel) {
      final ref = cacheRef(registry, repo, kind, key);
      final tmp = Directory.systemTemp.createTempSync('emb_pull_');
      try {
        await st.ensure(
          kind: kind,
          key: key,
          sourceUrl: ref,
          fetch: () => transport.pull(ref, tmp),
          stage: (blob, into) async {
            final r = await _run('tar', [
              '-xzf',
              blob.path,
              '-C',
              into.path,
            ], output: ProcessOutputMode.capture);
            if (r.exitCode != 0) {
              throw OciTransportException('untar $ref failed: ${r.stderr}');
            }
          },
        );
      } on OciTransportException catch (err) {
        _logger.err(err.message);
        return ExitCode.software.code;
      } finally {
        tmp.deleteSync(recursive: true);
      }
      if (link != null) {
        st.materialize(
          kind: kind,
          key: key,
          linkPath: p.join(link, '$kind-$key'),
        );
      }
      pulled.add(ref);
      if (!json) _logger.info('pulled $ref');
    }

    if (json) {
      _logger.info(
        jsonEnvelope('cache pull', ok: true, data: {'pulled': pulled}),
      );
    } else {
      _logger.info(
        'Pulled ${pulled.length} entr'
        '${pulled.length == 1 ? "y" : "ies"}.',
      );
    }
    return ExitCode.success.code;
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
