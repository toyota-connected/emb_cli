import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:emb_cli/src/cross/board_source.dart';
import 'package:emb_cli/src/cross/boards_dir.dart';
import 'package:emb_cli/src/cross/cross_project.dart';
import 'package:emb_cli/src/cross/cross_target.dart';
import 'package:emb_cli/src/cross/custom_device_builder.dart';
import 'package:emb_cli/src/cross/deployer.dart';
import 'package:emb_cli/src/cross/process_runner.dart';
import 'package:emb_cli/src/flutter/custom_devices_config.dart';
import 'package:emb_cli/src/manifest/manifest_loader.dart';
import 'package:emb_cli/src/version.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:path/path.dart' as p;

/// {@template boards_command}
/// `emb boards` — inspect and install the shipped board library that
/// `extends:` resolves against.
///
/// A `dart install`-ed emb is a standalone AOT binary carrying no package data
/// files, so the board library cannot travel with it. `bootstrap.sh` installs
/// it for a checkout; [BoardsSyncCommand] covers every other install path.
/// {@endtemplate}
class BoardsCommand extends Command<int> {
  /// {@macro boards_command}
  BoardsCommand({
    required Logger logger,
    HttpClient? httpClient,
    Map<String, String>? environment,
    Uri? apiBase,
    ProcessRunner? processRunner,
  }) {
    addSubcommand(BoardsListCommand(logger: logger, environment: environment));
    addSubcommand(
      BoardsCustomDevicesCommand(logger: logger, environment: environment),
    );
    addSubcommand(
      BoardsSyncCommand(
        logger: logger,
        httpClient: httpClient,
        environment: environment,
        apiBase: apiBase,
        processRunner: processRunner,
      ),
    );
    addSubcommand(BoardsAddCommand(logger: logger, environment: environment));
    addSubcommand(
      BoardsRemoveCommand(logger: logger, environment: environment),
    );
  }

  @override
  String get description =>
      'Inspect or install the board library that `extends:` resolves against.';

  @override
  String get name => 'boards';
}

/// `emb boards list` — the resolved board library, and where it came from.
class BoardsListCommand extends Command<int> {
  /// Creates the command.
  BoardsListCommand({required Logger logger, Map<String, String>? environment})
    : _logger = logger,
      _environment = environment ?? Platform.environment {
    argParser.addFlag(
      'sources',
      help: 'List configured board sources instead of board targets.',
      negatable: false,
    );
  }

  final Logger _logger;
  final Map<String, String> _environment;

  @override
  String get description => 'List the boards `extends:` can resolve.';

  @override
  String get name => 'list';

  @override
  Future<int> run() async {
    if (argResults?['sources'] == true) return _listSources();

    final resolver = CrossProjectResolver(
      const ManifestLoader(),
      null,
      _environment,
    );
    final names = resolver.boardNames();

    final dir = resolveBoardsDir(environment: _environment);

    _logger
      ..info('Source:  ${resolver.boardsProvenance ?? "not resolved"}')
      ..info('Install: ${dir.path}');

    // Per-source stamp reporting.
    final config = BoardSourceConfig.load(
      resolveBoardSourcesFile(environment: _environment),
      onWarning: _logger.warn,
    );
    var stampReported = false;
    for (final s in config.sources) {
      final sourceDir = switch (s) {
        LocalBoardSource(:final path) => Directory(path),
        _ => Directory(p.join(dir.path, s.name)),
      };
      final stamp = sourceDir.existsSync()
          ? readBoardsStamp(sourceDir)
          : null;
      if (stamp != null) {
        stampReported = true;
        _logger.info(
          'Version: $stamp (${s.name})'
          '${stamp == packageVersion ? "" : "  (emb is $packageVersion)"}',
        );
      }
    }
    // Legacy flat stamp — only if no per-source stamp was found.
    if (!stampReported && config.sources.length == 1 && dir.existsSync()) {
      final stamp = readBoardsStamp(dir);
      if (stamp != null) {
        _logger.info(
          'Version: $stamp'
          '${stamp == packageVersion ? "" : "  (emb is $packageVersion)"}',
        );
      }
    }

    if (names.isEmpty) {
      _logger
        ..warn('No boards are loaded.')
        ..info('Run `emb boards sync` to install the board library.');
      return ExitCode.unavailable.code;
    }

    // Group by source prefix.
    final grouped = <String, List<String>>{};
    for (final n in names) {
      final slash = n.indexOf('/');
      final source = slash >= 0 ? n.substring(0, slash) : '(unknown)';
      final target = slash >= 0 ? n.substring(slash + 1) : n;
      (grouped[source] ??= []).add(target);
    }

    _logger.info('');
    for (final MapEntry(key: source, value: targets)
        in grouped.entries) {
      _logger.info('$source:');
      for (final t in targets) {
        _logger.info('  $t');
      }
    }
    return ExitCode.success.code;
  }

  int _listSources() {
    final config = BoardSourceConfig.load(
      resolveBoardSourcesFile(environment: _environment),
      onWarning: _logger.warn,
    );
    final installed = resolveBoardsDir(environment: _environment);
    for (final s in config.sources) {
      final dir = switch (s) {
        LocalBoardSource(:final path) => Directory(path),
        _ => Directory(p.join(installed.path, s.name)),
      };
      final synced = switch (s) {
        LocalBoardSource() => dir.existsSync() ? 'found' : 'missing',
        _ => dir.existsSync() ? 'synced' : 'not synced',
      };
      final type = s is GithubBoardSource ? 'github' : 'local';
      _logger.info('${s.name} ($type, $synced)');
      final map = s.toMap()..remove('name')..remove('type');
      for (final e in map.entries) {
        _logger.info('  ${e.key}: ${e.value}');
      }
    }
    return ExitCode.success.code;
  }
}

/// `emb boards sync` — download the board library into the data dir.
class BoardsSyncCommand extends Command<int> {
  /// Creates the command.
  BoardsSyncCommand({
    required Logger logger,
    HttpClient? httpClient,
    Map<String, String>? environment,
    Uri? apiBase,
    ProcessRunner? processRunner,
  }) : _logger = logger,
       _http = httpClient ?? HttpClient(),
       _environment = environment ?? Platform.environment,
       _apiBase = apiBase ?? Uri.https('api.github.com', '/'),
       _runProcess = processRunner ?? defaultProcessRunner {
    argParser
      ..addOption(
        'ref',
        help:
            'Git ref to fetch from (default: the tag matching this emb, '
            'v$packageVersion). Applies to all GitHub sources unless '
            'the source config pins a specific ref.',
      )
      ..addOption(
        'source',
        help: 'Sync only the named source instead of all sources.',
      );
  }

  final Logger _logger;
  final HttpClient _http;
  final Map<String, String> _environment;
  final ProcessRunner _runProcess;

  /// Base of the contents API. Overridable so the fetch path can be tested
  /// against a local server instead of reaching GitHub.
  final Uri _apiBase;

  @override
  String get description =>
      'Download the board library into the emb data directory.';

  @override
  String get name => 'sync';

  @override
  Future<int> run() async {
    try {
      final refOverride = argResults?['ref'] as String?;
      final sourceFilter = argResults?['source'] as String?;
      final dest = resolveBoardsDir(environment: _environment);
      final config = BoardSourceConfig.load(
        resolveBoardSourcesFile(environment: _environment),
        onWarning: _logger.warn,
      );

      if (sourceFilter != null && !config.contains(sourceFilter)) {
        _logger.err('Unknown source "$sourceFilter". '
            'Known: ${config.sources.map((s) => s.name).join(", ")}.');
        return ExitCode.usage.code;
      }

      var synced = 0;
      final failed = <String>[];
      for (final source in config.sources) {
        if (sourceFilter != null && source.name != sourceFilter) continue;
        switch (source) {
          case GithubBoardSource():
            final code = await _syncGithub(source, dest, refOverride);
            if (code != ExitCode.success.code) {
              failed.add(source.name);
            } else {
              synced++;
            }
          case LocalBoardSource(:final path):
            final dir = Directory(path);
            if (!dir.existsSync()) {
              _logger.warn(
                'Local source "${source.name}" at $path does not exist.',
              );
              continue;
            }
            _logger.info(
              'Local source "${source.name}" at $path '
              '— no sync needed.',
            );
            synced++;
        }
      }

      if (synced == 0 && failed.isEmpty) {
        _logger.warn('No sources to sync.');
        return ExitCode.unavailable.code;
      }
      if (failed.isNotEmpty) {
        _logger.err('Failed to sync: ${failed.join(", ")}.');
        return ExitCode.unavailable.code;
      }
      return ExitCode.success.code;
    } finally {
      _http.close();
    }
  }

  static const _shaStamp = '.emb-boards-sha';

  Future<int> _syncGithub(
    GithubBoardSource source,
    Directory boardsRoot,
    String? refOverride,
  ) async {
    final ref = refOverride ??
        (source.ref == 'auto' ? 'v$packageVersion' : source.ref);
    final sourceDest = Directory(p.join(boardsRoot.path, source.name));
    final shaFile = File(p.join(sourceDest.path, _shaStamp));

    final progress = _logger.progress(
      'Checking ${source.name} (${source.repo}) at $ref',
    );

    final String remoteSha;
    try {
      remoteSha = source.useSsh
          ? await _remoteSshSha(source, ref)
          : await _remoteApiSha(source, ref);
    } on Object catch (e) {
      progress.fail(
        'Could not check ${source.name} at $ref',
      );
      _logger.err('$e');
      return ExitCode.unavailable.code;
    }

    final localSha = shaFile.existsSync()
        ? shaFile.readAsStringSync().trim()
        : '';
    if (localSha == remoteSha) {
      progress.complete('${source.name}: up to date ($ref)');
      return ExitCode.success.code;
    }

    progress.update(
      'Fetching ${source.name} (${source.repo}) at $ref',
    );

    final int count;
    try {
      count = source.useSsh
          ? await _fetchBoardsSsh(source, ref, sourceDest, progress)
          : await _fetchBoardsApi(source, ref, sourceDest, progress);
    } on Object catch (e) {
      progress.fail('Could not sync ${source.name} at $ref');
      _logger.err('$e');
      return ExitCode.unavailable.code;
    }
    if (count == 0) {
      progress.fail(
        'No board files found for ${source.name} at $ref',
      );
      return ExitCode.unavailable.code;
    }

    File(
      p.join(sourceDest.path, boardsVersionStamp),
    ).writeAsStringSync('$packageVersion\n');
    shaFile.writeAsStringSync('$remoteSha\n');

    progress.complete(
      '${source.name}: installed $count board file(s)',
    );
    _logger.info(sourceDest.path);
    return ExitCode.success.code;
  }

  // -- Transport: remote SHA -------------------------------------------

  Future<String> _remoteApiSha(
    GithubBoardSource source,
    String ref,
  ) async {
    final api = _apiBase.replace(
      path: '/repos/${source.repo}/commits/${Uri.encodeComponent(ref)}',
    );
    final decoded = jsonDecode(utf8.decode(await _get(api, source)));
    if (decoded is Map && decoded['sha'] is String) {
      return decoded['sha'] as String;
    }
    throw StateError(
      'unexpected response fetching commit SHA for $ref',
    );
  }

  Future<String> _remoteSshSha(
    GithubBoardSource source,
    String ref,
  ) async {
    final sshUrl = 'git@github.com:${source.repo}.git';
    final result = await _runProcess(
      'git',
      ['ls-remote', sshUrl, ref, '$ref^{}'],
    );
    if (result.exitCode != 0) {
      throw StateError(
        result.stderr.isNotEmpty ? result.stderr : result.stdout,
      );
    }
    // For annotated tags ls-remote returns both the tag object and the
    // dereferenced commit (the ^{} line). Prefer the commit SHA so the
    // staleness check is consistent with the HTTPS /commits/ endpoint.
    String? sha;
    for (final line in result.stdout.split('\n')) {
      final parts = line.split(RegExp(r'\s+'));
      if (parts.length < 2 || parts[0].isEmpty) continue;
      sha = parts[0];
      if (line.contains('^{}')) break;
    }
    if (sha == null || sha.isEmpty) {
      throw StateError('ref "$ref" not found in ${source.repo}');
    }
    return sha;
  }

  // -- Transport: fetch board files ------------------------------------

  Future<int> _fetchBoardsApi(
    GithubBoardSource source,
    String ref,
    Directory dest,
    Progress progress,
  ) async {
    final entries = await _listBoards(source, ref);
    if (entries.isEmpty) return 0;

    dest.createSync(recursive: true);
    final written = <String>{};
    for (final e in entries) {
      progress.update('Fetching ${e.name}');
      final bytes = await _get(
        e.url, source, accept: 'application/vnd.github.raw+json',
      );
      File(p.join(dest.path, e.name)).writeAsBytesSync(bytes);
      written.add(e.name);
    }
    for (final f in dest.listSync().whereType<File>().where(
      (f) => f.path.endsWith('.emb.yaml') &&
          !written.contains(p.basename(f.path)),
    )) {
      f.deleteSync();
    }
    return entries.length;
  }

  Future<int> _fetchBoardsSsh(
    GithubBoardSource source,
    String ref,
    Directory dest,
    Progress progress,
  ) async {
    final sshUrl = 'git@github.com:${source.repo}.git';
    final tmp = Directory.systemTemp.createTempSync('emb_boards_');
    try {
      // --branch accepts tags and branch names but not raw SHAs. For a SHA
      // we clone without --branch and fetch the exact commit instead.
      final isSha = RegExp(r'^[0-9a-f]{7,40}$').hasMatch(ref);
      final clone = await _runProcess('git', [
        'clone',
        '--depth',
        '1',
        if (!isSha) '--branch',
        if (!isSha) ref,
        '--filter=blob:none',
        '--sparse',
        sshUrl,
        tmp.path,
      ]);
      if (clone.exitCode != 0) {
        throw StateError(
          clone.stderr.isNotEmpty ? clone.stderr : clone.stdout,
        );
      }
      if (isSha) {
        final fetch = await _runProcess(
          'git',
          ['fetch', 'origin', ref],
          workingDirectory: tmp.path,
        );
        if (fetch.exitCode != 0) {
          throw StateError(
            fetch.stderr.isNotEmpty ? fetch.stderr : fetch.stdout,
          );
        }
        final checkout = await _runProcess(
          'git',
          ['checkout', ref],
          workingDirectory: tmp.path,
        );
        if (checkout.exitCode != 0) {
          throw StateError(
            checkout.stderr.isNotEmpty ? checkout.stderr : checkout.stdout,
          );
        }
      }

      final sparseSet = await _runProcess('git', [
        'sparse-checkout',
        'set',
        source.path,
      ], workingDirectory: tmp.path);
      if (sparseSet.exitCode != 0) {
        throw StateError(sparseSet.stderr);
      }

      final srcDir = Directory(p.join(tmp.path, source.path));
      if (!srcDir.existsSync()) return 0;

      final files = srcDir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.emb.yaml'))
          .toList();
      if (files.isEmpty) return 0;

      dest.createSync(recursive: true);
      final written = <String>{};
      for (final f in files) {
        final name = p.basename(f.path);
        f.copySync(p.join(dest.path, name));
        written.add(name);
      }
      for (final existing in dest.listSync().whereType<File>().where(
        (f) => f.path.endsWith('.emb.yaml') &&
            !written.contains(p.basename(f.path)),
      )) {
        existing.deleteSync();
      }
      return files.length;
    } finally {
      try {
        tmp.deleteSync(recursive: true);
      } on Object catch (e) {
        _logger.detail('cleanup of ${tmp.path} failed: $e');
      }
    }
  }

  /// The `boards/*.emb.yaml` entries at [ref], via the GitHub contents API.
  Future<List<({String name, Uri url})>> _listBoards(
    GithubBoardSource source,
    String ref,
  ) async {
    final api = _apiBase.replace(
      path: '/repos/${source.repo}/contents/${source.path}',
      queryParameters: {'ref': ref},
    );
    final decoded = jsonDecode(utf8.decode(await _get(api, source)));
    if (decoded is! List) {
      throw StateError(
        'unexpected response listing boards for ${source.name} at $ref',
      );
    }
    return [
      for (final e in decoded)
        if (e is Map &&
            e['type'] == 'file' &&
            '${e['name']}'.endsWith('.emb.yaml') &&
            e['url'] != null)
          (name: '${e['name']}', url: Uri.parse('${e['url']}')),
    ];
  }

  Future<List<int>> _get(
    Uri url,
    GithubBoardSource source, {
    String? accept,
  }) async {
    final req = await _http.getUrl(url)
      ..headers.set(HttpHeaders.userAgentHeader, 'emb/$packageVersion')
      ..headers.set(
        HttpHeaders.acceptHeader,
        accept ?? 'application/vnd.github+json',
      );
    if (source.tokenEnv != null &&
        url.host == _apiBase.host) {
      final token = _environment[source.tokenEnv!];
      if (token != null && token.isNotEmpty) {
        req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      }
    }
    final res = await req.close();
    if (res.statusCode != HttpStatus.ok) {
      await res.drain<void>();
      throw HttpException('HTTP ${res.statusCode} for $url');
    }
    return [for (final chunk in await res.toList()) ...chunk];
  }
}


/// `emb boards add` — add a board source to the config.
class BoardsAddCommand extends Command<int> {
  /// Creates the command.
  BoardsAddCommand({required Logger logger, Map<String, String>? environment})
    : _logger = logger,
      _environment = environment ?? Platform.environment {
    argParser
      ..addOption(
        'name',
        abbr: 'n',
        help: 'Source name (required).',
        mandatory: true,
      )
      ..addOption(
        'path',
        help: 'Subdirectory within the repo (github) '
            'or local path.',
      )
      ..addOption(
        'ref',
        help: 'Git ref (github). '
            '"auto" tracks emb version.',
        defaultsTo: 'main',
      )
      ..addOption(
        'token-env',
        help: 'Env var holding a GitHub PAT.',
      )
      ..addOption(
        'transport',
        help: 'Transport protocol: https (GitHub API) or ssh (git clone).',
        allowed: ['https', 'ssh'],
        defaultsTo: 'https',
      );
  }

  final Logger _logger;
  final Map<String, String> _environment;

  @override
  String get description => 'Add a board source (github or local).';

  @override
  String get name => 'add';

  @override
  String get invocation => 'emb boards add <type> <repo-or-path>';

  @override
  Future<int> run() async {
    final args = argResults!;
    if (args.rest.length < 2) {
      _logger.err(
        'Usage: emb boards add <github|local> <repo-or-path> --name <name>',
      );
      return ExitCode.usage.code;
    }
    final type = args.rest[0];
    final target = args.rest[1];
    final sourceName = args['name'] as String;

    final file = resolveBoardSourcesFile(environment: _environment);
    final config = BoardSourceConfig.load(file, onWarning: _logger.warn);

    if (!validSourceName.hasMatch(sourceName)) {
      _logger.err(
        'Invalid source name "$sourceName". '
        'Use only letters, digits, dashes, and underscores.',
      );
      return ExitCode.usage.code;
    }

    if (config.contains(sourceName)) {
      _logger.err('Source "$sourceName" already exists. '
          'Remove it first with `emb boards remove $sourceName`.');
      return ExitCode.config.code;
    }

    final BoardSource source;
    switch (type) {
      case 'github':
        if (!validRepoRef.hasMatch(target)) {
          _logger.err(
            'Invalid repo "$target". Use "owner/repo" format.',
          );
          return ExitCode.usage.code;
        }
        final sourcePath = args['path'] as String? ?? 'boards';
        if (sourcePath.split('/').contains('..')) {
          _logger.err(
            'Invalid path "$sourcePath". Must not contain "..".',
          );
          return ExitCode.usage.code;
        }
        source = GithubBoardSource(
          name: sourceName,
          repo: target,
          path: sourcePath,
          ref: args['ref'] as String,
          tokenEnv: args['token-env'] as String?,
          transport: args['transport'] as String,
        );
      case 'local':
        source = LocalBoardSource(name: sourceName, path: target);
      default:
        _logger.err('Unknown source type "$type". Use "github" or "local".');
        return ExitCode.usage.code;
    }

    BoardSourceConfig([...config.sources, source]).save(file);
    _logger.info('Added source "$sourceName" → $file');
    if (source is GithubBoardSource) {
      _logger.info('Run `emb boards sync --source $sourceName` to fetch.');
    }
    return ExitCode.success.code;
  }
}

/// `emb boards remove` — remove a board source from the config.
class BoardsRemoveCommand extends Command<int> {
  /// Creates the command.
  BoardsRemoveCommand({
    required Logger logger,
    Map<String, String>? environment,
  }) : _logger = logger,
       _environment = environment ?? Platform.environment;

  final Logger _logger;
  final Map<String, String> _environment;

  @override
  String get description => 'Remove a configured board source.';

  @override
  String get name => 'remove';

  @override
  String get invocation => 'emb boards remove <source-name>';

  @override
  Future<int> run() async {
    final args = argResults!;
    if (args.rest.isEmpty) {
      _logger.err('Usage: emb boards remove <source-name>');
      return ExitCode.usage.code;
    }
    final sourceName = args.rest.first;

    if (!validSourceName.hasMatch(sourceName)) {
      _logger.err(
        'Invalid source name "$sourceName". '
        'Use only letters, digits, dashes, and underscores.',
      );
      return ExitCode.usage.code;
    }

    final file = resolveBoardSourcesFile(environment: _environment);
    final config = BoardSourceConfig.load(file, onWarning: _logger.warn);

    if (!config.contains(sourceName)) {
      _logger.err(
        'No source named "$sourceName". '
        'Known: ${config.sources.map((s) => s.name).join(", ")}.',
      );
      return ExitCode.usage.code;
    }

    final updated = config.sources.where((s) => s.name != sourceName).toList();
    BoardSourceConfig(updated).save(file);
    _logger.info('Removed source "$sourceName".');
    if (updated.isEmpty) {
      _logger.warn(
        'No sources remain. The default source will be restored on next load.',
      );
    }

    // Clean up the synced directory if it exists.
    final dir = Directory(
      p.join(resolveBoardsDir(environment: _environment).path, sourceName),
    );
    if (dir.existsSync()) {
      _logger.info('Removing synced boards at ${dir.path}');
      dir.deleteSync(recursive: true);
    }
    return ExitCode.success.code;
  }
}

/// `emb boards custom-devices` — register a board target with Flutter as a
/// custom device, so `flutter run -d <id>` (and with it hot reload, debugging
/// and DevTools) drives the board directly.
///
/// The entry is derived, never restated: the board file declares only the
/// `cross.custom_device` metadata (id/label), and the commands Flutter runs
/// come from the same transport and deploy dir `emb cross --deploy` uses.
class BoardsCustomDevicesCommand extends Command<int> {
  /// Creates the command.
  BoardsCustomDevicesCommand({
    required Logger logger,
    Map<String, String>? environment,
    ManifestLoader loader = const ManifestLoader(),
    String? operatingSystem,
  }) : _logger = logger,
       _environment = environment ?? Platform.environment,
       _loader = loader,
       _os = operatingSystem {
    argParser
      ..addOption(
        'target',
        abbr: 't',
        help:
            'Board target to register (as `emb cross --target`). Omit to '
            'register every target that declares cross.custom_device.',
      )
      ..addOption(
        'deploy-dir',
        defaultsTo: 'ivi-homescreen',
        help:
            'Bundle root on the board — must match the --deploy-dir the '
            'bundle was deployed to.',
      )
      ..addOption(
        'bin',
        help:
            'Embedder binary inside the bundle. Defaults to the basename of '
            'cross.package.bin, else "homescreen".',
      )
      ..addFlag(
        'dry-run',
        help: 'Print the entries that would be written and change nothing.',
        negatable: false,
      );
  }

  final Logger _logger;
  final Map<String, String> _environment;
  final ManifestLoader _loader;
  final String? _os;

  @override
  String get description =>
      'Register board targets with Flutter as custom devices.';

  @override
  String get name => 'custom-devices';

  @override
  String get invocation => 'emb boards custom-devices [<manifest|dir>]';

  @override
  Future<int> run() async {
    final args = argResults!;
    final input = args.rest.isEmpty ? '.' : args.rest.first;

    final CrossProject? project;
    try {
      project = CrossProjectResolver(
        _loader,
        null,
        _environment,
      ).resolve(input);
    } on CrossProjectException catch (e) {
      _logger.err(e.message);
      return ExitCode.config.code;
    }
    if (project == null) {
      _logger.err('no emb manifest at "$input".');
      return ExitCode.noInput.code;
    }

    final wanted = args['target'] as String?;
    final refs = <String, CrossTargetRef>{
      for (final e in project.targets.entries)
        if (wanted == null || e.key == wanted) e.key: e.value,
    };
    if (wanted != null && refs.isEmpty) {
      _logger.err(
        'unknown target "$wanted" — known: ${project.targets.keys.join(", ")}',
      );
      return ExitCode.usage.code;
    }

    // Only targets that opted in. A board file without a custom_device block
    // is not an error: most targets are build-only.
    final registrable = <String, CrossTarget>{};
    for (final e in refs.entries) {
      final t = CrossTarget.fromMap(e.value.cross);
      if (t.customDevice != null) registrable[e.key] = t;
    }
    if (registrable.isEmpty) {
      _logger
        ..warn(
          wanted == null
              ? 'no target declares cross.custom_device.'
              : 'target "$wanted" declares no cross.custom_device.',
        )
        ..info(
          'Add one to the board target to register it with Flutter:\n'
          '  cross:\n'
          '    targets:\n'
          '      <target>:\n'
          '        custom_device: { id: <id>, label: <label> }',
        );
      return ExitCode.usage.code;
    }

    final deployDir = args['deploy-dir'] as String;
    final dryRun = args['dry-run'] == true;
    final file = resolveCustomDevicesConfig(
      environment: _environment,
      operatingSystem: _os,
    );

    for (final e in registrable.entries) {
      final target = e.value;
      final spec = target.customDevice!;
      final device = _deployTargetFor(target);
      final Map<String, dynamic> entry;
      try {
        entry = buildCustomDevice(
          spec: spec,
          device: device,
          deployDir: deployDir,
          binName: args['bin'] as String? ?? _binOf(target),
          triple: target.targetTriple,
          targetName: e.key,
        );
      } on CustomDeviceException catch (err) {
        _logger.err('${e.key}: ${err.message}');
        return ExitCode.config.code;
      }

      if (dryRun) {
        _logger
          ..info('${e.key} → ${spec.id} (would write ${file.path})')
          ..info(const JsonEncoder.withIndent('  ').convert(entry));
        continue;
      }
      final write = writeCustomDevice(file, entry);
      _logger.info(
        '  ${write.replaced ? "Updated" : "Registered"} '
        "'${write.id}' (${e.key}) → ${write.file.path}",
      );
    }

    if (!dryRun) {
      final first = registrable.values.first.customDevice!.id;
      _logger
        ..info('')
        ..info('Run it with:  flutter run -d $first')
        ..info(
          'Custom devices must be enabled: '
          'flutter config --enable-custom-devices',
        );
    }
    return ExitCode.success.code;
  }

  /// The deploy endpoint a target's device block describes. Mirrors what
  /// `emb cross --deploy` resolves, so a registered device and a deploy agree.
  DeployTarget _deployTargetFor(CrossTarget target) {
    final spec = target.sysroot;
    if (spec?.transport == DeviceTransport.adb) {
      return DeployTarget.adb(serial: spec?.adbSerial);
    }
    final fromDevice = spec?.source == SysrootProvenance.device;
    return DeployTarget.ssh(
      spec?.deviceHost ?? '',
      port: fromDevice ? spec!.sshPort : 22,
      opts: fromDevice ? spec!.sshOpts : null,
    );
  }

  /// The embedder name on the board: the basename of `cross.package.bin`
  /// (`shell/homescreen` → `homescreen`), else the historical default.
  String _binOf(CrossTarget target) {
    final bin = target.package?.bin;
    if (bin == null || bin.trim().isEmpty) return 'homescreen';
    return p.basename(bin);
  }
}
