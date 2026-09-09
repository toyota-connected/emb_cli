import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:emb_cli/src/cross/boards_dir.dart';
import 'package:emb_cli/src/cross/cross_project.dart';
import 'package:emb_cli/src/cross/cross_target.dart';
import 'package:emb_cli/src/cross/custom_device_builder.dart';
import 'package:emb_cli/src/cross/deployer.dart';
import 'package:emb_cli/src/flutter/custom_devices_config.dart';
import 'package:emb_cli/src/manifest/manifest_loader.dart';
import 'package:emb_cli/src/version.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:path/path.dart' as p;

/// GitHub repository the board library is fetched from.
const _repoSlug = 'toyota-connected/emb_cli';

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
      ),
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
      _environment = environment ?? Platform.environment;

  final Logger _logger;
  final Map<String, String> _environment;

  @override
  String get description => 'List the boards `extends:` can resolve.';

  @override
  String get name => 'list';

  @override
  Future<int> run() async {
    // Going through the resolver rather than reading the directory directly
    // means this reports exactly what `extends:` would see, including which
    // rung won -- the question people actually have when it misbehaves.
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

    final stamp = dir.existsSync() ? readBoardsStamp(dir) : null;
    if (stamp != null) {
      _logger.info(
        'Version: $stamp'
        '${stamp == packageVersion ? "" : "  (emb is $packageVersion)"}',
      );
    }

    if (names.isEmpty) {
      _logger
        ..warn('No boards are loaded.')
        ..info('Run `emb boards sync` to install the board library.');
      return ExitCode.unavailable.code;
    }
    _logger.info('');
    for (final n in names) {
      _logger.info('  $n');
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
  }) : _logger = logger,
       _http = httpClient ?? HttpClient(),
       _environment = environment ?? Platform.environment,
       _apiBase = apiBase ?? Uri.https('api.github.com', '/') {
    argParser.addOption(
      'ref',
      help:
          'Git ref to fetch from (default: the tag matching this emb, '
          'v$packageVersion).',
    );
  }

  final Logger _logger;
  final HttpClient _http;
  final Map<String, String> _environment;

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
    final ref = (argResults?['ref'] as String?) ?? 'v$packageVersion';
    final dest = resolveBoardsDir(environment: _environment);

    // An explicit, user-invoked network step on purpose. Fetching lazily on an
    // `extends:` miss would put the network behind parse-only operations and
    // break `--offline` and `emb matrix`'s side-effect-free contract.
    final progress = _logger.progress('Fetching board library at $ref');
    final List<({String name, Uri url})> entries;
    try {
      entries = await _listBoards(ref);
    } on Object catch (e) {
      progress.fail('Could not list boards at $ref');
      _logger
        ..err('$e')
        ..info(
          'If this emb is newer than the published tag, pass an existing ref: '
          'emb boards sync --ref main',
        );
      return ExitCode.unavailable.code;
    }
    if (entries.isEmpty) {
      progress.fail('No board files found at $ref');
      return ExitCode.unavailable.code;
    }

    try {
      dest.createSync(recursive: true);
      for (final e in entries) {
        progress.update('Fetching ${e.name}');
        final bytes = await _get(e.url);
        File(p.join(dest.path, e.name)).writeAsBytesSync(bytes);
      }
      File(
        p.join(dest.path, boardsVersionStamp),
      ).writeAsStringSync('$packageVersion\n');
    } on Object catch (e) {
      progress.fail('Could not write ${dest.path}');
      _logger.err('$e');
      return ExitCode.cantCreate.code;
    }

    progress.complete('Installed ${entries.length} board file(s)');
    _logger.info(dest.path);
    return ExitCode.success.code;
  }

  /// The `boards/*.emb.yaml` entries at [ref], via the GitHub contents API.
  Future<List<({String name, Uri url})>> _listBoards(String ref) async {
    final api = _apiBase.replace(
      path: '/repos/$_repoSlug/contents/boards',
      queryParameters: {'ref': ref},
    );
    final decoded = jsonDecode(utf8.decode(await _get(api)));
    if (decoded is! List) {
      throw StateError('unexpected response listing boards at $ref');
    }
    return [
      for (final e in decoded)
        if (e is Map &&
            e['type'] == 'file' &&
            '${e['name']}'.endsWith('.emb.yaml') &&
            e['download_url'] != null)
          (name: '${e['name']}', url: Uri.parse('${e['download_url']}')),
    ];
  }

  Future<List<int>> _get(Uri url) async {
    final req = await _http.getUrl(url)
      ..headers.set(HttpHeaders.userAgentHeader, 'emb/$packageVersion')
      ..headers.set(HttpHeaders.acceptHeader, 'application/vnd.github+json');
    final res = await req.close();
    if (res.statusCode != HttpStatus.ok) {
      throw HttpException('HTTP ${res.statusCode} for $url');
    }
    return [for (final chunk in await res.toList()) ...chunk];
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
