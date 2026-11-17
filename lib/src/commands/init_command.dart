import 'dart:io';
import 'dart:typed_data';

import 'package:args/command_runner.dart';
import 'package:emb_cli/src/cross/cross_project.dart';
import 'package:emb_cli/src/cross/cross_target.dart';
import 'package:emb_cli/src/cross/flatpak_packager.dart';
import 'package:emb_cli/src/init/flatpak_repo_template.dart';
import 'package:emb_cli/src/version.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

/// Runs a host tool (`git`, `flatpak`) for [InitFlatpakCommand]; injectable so
/// tests need neither the network nor flatpak.
typedef InitProcessRunner =
    Future<ProcessResult> Function(String executable, List<String> args);

Future<ProcessResult> _defaultRunner(String executable, List<String> args) =>
    Process.run(executable, args);

/// {@template init_command}
/// `emb init <format>` — generate a packaging repo for one format.
///
/// A dispatcher from the start, with `flatpak` the only format, so a second
/// one is a subcommand and not a restructuring.
/// {@endtemplate}
class InitCommand extends Command<int> {
  /// {@macro init_command}
  InitCommand({
    required Logger logger,
    InitProcessRunner? processRunner,
    CrossProjectResolver? resolver,
  }) {
    addSubcommand(
      InitFlatpakCommand(
        logger: logger,
        processRunner: processRunner,
        resolver: resolver,
      ),
    );
  }

  @override
  String get description => 'Generate a packaging repo (flatpak).';

  @override
  String get name => 'init';
}

/// {@template init_flatpak_command}
/// `emb init flatpak <dir> --app-id <id>` — write a self-contained flatpak
/// packaging repo: a cross manifest naming its own embedder, app, Flutter SDK
/// and runtime, plus the README, `.gitignore`, AppStream metadata and CI
/// around it. Non-interactive; everything comes from flags or is inferred.
/// {@endtemplate}
class InitFlatpakCommand extends Command<int> {
  /// {@macro init_flatpak_command}
  InitFlatpakCommand({
    required Logger logger,
    InitProcessRunner? processRunner,
    CrossProjectResolver? resolver,
  }) : _logger = logger,
       _run = processRunner ?? _defaultRunner,
       _resolver = resolver ?? CrossProjectResolver() {
    argParser
      ..addOption(
        'app-id',
        help: 'Reverse-DNS flatpak app id, e.g. com.example.MyApp.',
        mandatory: true,
      )
      ..addOption(
        'app',
        help:
            'The Flutter app. A git URI is written into the manifest as '
            'cross.app; a local directory only supplies the name, version '
            'and description from its pubspec.yaml.',
      )
      ..addOption(
        'app-rev',
        help: 'Commit of --app <uri> to pin (default: its HEAD, resolved now).',
      )
      ..addOption(
        'embedder',
        help: 'Git URI of the embedder, written as cross.source.',
        defaultsTo: defaultEmbedderUri,
      )
      ..addOption(
        'embedder-rev',
        help: 'Embedder commit to pin (default: its HEAD, resolved now).',
      )
      ..addOption(
        'embedder-bin',
        help:
            'The embedder binary, relative to its build directory '
            '(default for ivi-homescreen: $defaultEmbedderBin).',
      )
      ..addOption(
        'provider',
        help: 'Cross provider the manifest declares.',
        allowed: [for (final k in CrossProviderKind.values) k.token],
        defaultsTo: CrossProviderKind.armGnu.token,
      )
      ..addOption(
        'target',
        help: 'A board to add as a cross target (extends: <board>).',
      )
      ..addOption(
        'runtime-version',
        help:
            'freedesktop runtime branch (default: the newest flathub offers, '
            'else $fallbackFlatpakRuntimeVersion).',
      )
      ..addOption(
        'flutter-version',
        help: 'Flutter SDK branch or tag the manifest pins.',
        defaultsTo: 'stable',
      )
      ..addOption(
        'ci',
        help: 'CI workflow to generate. Needs --app <uri>.',
        allowed: const ['none', 'github'],
        defaultsTo: 'github',
      )
      ..addFlag(
        'force',
        help:
            'Write into a non-empty directory. Only files emb generated are '
            'replaced; any other file is left as it is.',
        negatable: false,
      );
  }

  final Logger _logger;
  final InitProcessRunner _run;
  final CrossProjectResolver _resolver;

  @override
  String get description =>
      'Generate a self-contained flatpak packaging repo in <dir>.';

  @override
  String get name => 'flatpak';

  @override
  String get invocation => 'emb init flatpak <dir> --app-id <id> [options]';

  @override
  Future<int> run() async {
    final args = argResults!;
    if (args.rest.length != 1) {
      throw UsageException(
        args.rest.isEmpty
            ? 'init flatpak: missing the directory to generate into.'
            : 'init flatpak: unexpected argument "${args.rest[1]}".',
        usage,
      );
    }
    final dir = Directory(args.rest.single);
    final force = args['force'] as bool;

    // Reading an unset mandatory option throws ArgumentError, which would
    // reach the user as a crash and not as usage.
    if (!args.wasParsed('app-id')) {
      throw UsageException('init flatpak: --app-id is required.', usage);
    }
    final appId = args['app-id'] as String;
    if (!looksLikeFlatpakAppId(appId)) {
      _logger.err(
        'Invalid flatpak app id "$appId": expected reverse-DNS with at '
        'least three segments, e.g. com.example.MyApp.',
      );
      return ExitCode.usage.code;
    }

    // Refuse before any network work: a directory that cannot be written is
    // known now, and resolving two remotes first only delays saying so.
    if (!force && dir.existsSync() && dir.listSync().isNotEmpty) {
      _logger.err(
        '${dir.path} is not empty. Pass --force to write into it; files emb '
        'did not generate are left alone.',
      );
      return ExitCode.cantCreate.code;
    }

    // --app: a URI goes into the manifest, a directory only describes the app.
    final appArg = args['app'] as String?;
    final appIsUri = appArg != null && _isGitUri(appArg);
    _Pubspec? pubspec;
    if (appArg != null && !appIsUri) {
      pubspec = _readPubspec(Directory(appArg));
      if (pubspec == null) {
        _logger.err(
          '--app $appArg: no readable pubspec.yaml there. Give a Flutter app '
          'directory, or a git URI.',
        );
        return ExitCode.usage.code;
      }
    }
    if (args['app-rev'] != null && !appIsUri) {
      _logger.err('--app-rev needs --app <uri>.');
      return ExitCode.usage.code;
    }

    // Whether the board exists is settled by [_verify], which resolves the
    // manifest the way `emb cross` does. All that can be said up front is
    // that there is no library to resolve it against.
    final target = args['target'] as String?;
    final haveBoards = _haveBoards();
    if (target != null && !haveBoards) {
      _logger.warn(
        'No board library found, so "$target" could not be checked. Run '
        '`emb boards sync` before building.',
      );
    }

    final embedder = await _pin(
      'embedder',
      args['embedder'] as String,
      args['embedder-rev'] as String?,
      flag: '--embedder-rev',
    );
    if (embedder == null) return ExitCode.unavailable.code;
    PinnedRepo? app;
    if (appIsUri) {
      app = await _pin(
        'app',
        appArg,
        args['app-rev'] as String?,
        flag: '--app-rev',
      );
      if (app == null) return ExitCode.unavailable.code;
    }

    final wantsCi = args['ci'] == 'github';
    final spec = FlatpakRepoSpec(
      appId: appId,
      id: pubspec == null ? idFromAppId(appId) : kebabCase(pubspec.name),
      name: pubspec?.name ?? appId.split('.').last,
      version: pubspec?.version ?? '0.1.0',
      summary: pubspec?.description,
      embedder: embedder,
      // Only ivi-homescreen's layout is known. For any other embedder the
      // manifest says the binary should be named, and why.
      embedderBin:
          (args['embedder-bin'] as String?) ??
          (embedder.uri == defaultEmbedderUri ? defaultEmbedderBin : null),
      app: app,
      provider: args['provider'] as String,
      target: target,
      runtimeVersion:
          (args['runtime-version'] as String?) ?? await _newestRuntime(),
      flutterVersion: args['flutter-version'] as String,
      githubCi: wantsCi,
      embVersion: packageVersion,
    );
    if (spec.id.isEmpty) {
      _logger.err('Could not derive a package name from "$appId".');
      return ExitCode.usage.code;
    }

    final files = renderFlatpakRepo(spec);
    final problem = _verify(files, spec, haveBoards: haveBoards);
    if (problem != null) {
      // The one input that can make a rendered manifest unloadable is a
      // board that does not exist; anything else is a defect in the template.
      _logger.err(problem);
      return target != null ? ExitCode.usage.code : ExitCode.software.code;
    }

    final binaries = renderFlatpakRepoBinaries(spec);
    final kept = {..._write(dir, files), ..._writeBinaries(dir, binaries)};
    for (final rel in [...files.keys, ...binaries.keys]) {
      _logger.info(
        kept.contains(rel)
            ? '  kept     $rel (not generated by emb)'
            : '  wrote    $rel',
      );
    }
    if (wantsCi && !spec.emitsWorkflow) {
      _logger.info(
        '  no CI workflow: the app is not named in the manifest, so a runner '
        'would have nothing to build. Pass --app <uri> to get one.',
      );
    }
    _logger
      ..info('')
      ..info('Next, in ${dir.path}:')
      ..info('  ${spec.buildCommand}');
    return ExitCode.success.code;
  }

  bool _isGitUri(String value) =>
      value.contains('://') || RegExp(r'^[\w.-]+@[\w.-]+:').hasMatch(value);

  /// Whether there is a board library to resolve `extends:` against. A
  /// compiled emb has none until `emb boards sync`.
  bool _haveBoards() {
    try {
      return _resolver.boardNames().isNotEmpty;
    } on CrossProjectException {
      return false;
    }
  }

  /// [uri] pinned to [rev], or to its HEAD when [rev] is null. Null (after
  /// reporting) when HEAD cannot be resolved.
  ///
  /// A commit, not a branch: a branch floats and the build breaks at a
  /// distance. The branch is kept beside it as the thing to edit.
  Future<PinnedRepo?> _pin(
    String what,
    String uri,
    String? rev, {
    required String flag,
  }) async {
    if (rev != null) return PinnedRepo(uri: uri, rev: rev);
    final ProcessResult r;
    try {
      r = await _run('git', ['ls-remote', '--symref', uri, 'HEAD']);
    } on ProcessException catch (e) {
      _logger.err('Could not run git to resolve the $what: ${e.message}');
      return null;
    }
    String? sha;
    String? branch;
    for (final line in (r.stdout as String).split('\n')) {
      final fields = line.trim().split(RegExp(r'\s+'));
      if (fields.length == 3 && fields[0] == 'ref:' && fields[2] == 'HEAD') {
        branch = fields[1].replaceFirst('refs/heads/', '');
      } else if (fields.length == 2 && fields[1] == 'HEAD') {
        sha = fields[0];
      }
    }
    if (r.exitCode != 0 || sha == null) {
      _logger.err(
        'Could not resolve HEAD of $uri '
        '(${(r.stderr as String).trim().split('\n').first}). '
        'Pass $flag <commit> to pin the $what without the network.',
      );
      return null;
    }
    return PinnedRepo(uri: uri, rev: sha, branch: branch);
  }

  /// The newest `org.freedesktop.Platform` branch flathub offers, as seen by
  /// the user or the system installation; the fallback when flatpak is not
  /// installed or has no flathub remote.
  Future<String> _newestRuntime() async {
    final branches = <String>{};
    for (final scope in const ['--user', '--system']) {
      try {
        final r = await _run('flatpak', [
          'remote-ls',
          scope,
          '--runtime',
          '--columns=application,branch',
          'flathub',
        ]);
        if (r.exitCode != 0) continue;
        for (final line in (r.stdout as String).split('\n')) {
          final fields = line.trim().split(RegExp(r'\s+'));
          if (fields.length == 2 &&
              fields[0] == 'org.freedesktop.Platform' &&
              RegExp(r'^\d\d\.\d\d$').hasMatch(fields[1])) {
            branches.add(fields[1]);
          }
        }
      } on ProcessException {
        continue;
      }
      if (branches.isNotEmpty) break;
    }
    if (branches.isEmpty) return fallbackFlatpakRuntimeVersion;
    // `YY.MM`, zero-padded, so string order is version order.
    return (branches.toList()..sort()).last;
  }

  /// Resolves the rendered manifest the way `emb cross` would, from a scratch
  /// copy, so nothing is written into the user's directory unless what is
  /// written will load. Returns the problem, or null.
  String? _verify(
    Map<String, String> files,
    FlatpakRepoSpec spec, {
    required bool haveBoards,
  }) {
    final scratch = Directory.systemTemp.createTempSync('emb-init-');
    try {
      final manifest = File(p.join(scratch.path, spec.manifestName))
        ..writeAsStringSync(files[spec.manifestName]!);
      final project = _resolver.resolve(manifest.path);
      if (project == null) return 'no manifest was produced';
      final selection = project.selectTarget(spec.buildTarget);
      if (selection == null) return 'target "${spec.buildTarget}" is missing';
      final target = CrossTarget.fromMap(selection.cross);
      if (target.package?.flatpak?.appId != spec.appId) {
        return 'package.flatpak.app_id did not survive';
      }
      return null;
    } on CrossProjectException catch (e) {
      // With no board library the board cannot be loaded here either; that
      // was already warned about and is not a defect in what was rendered.
      if (spec.target != null && !haveBoards) return null;
      // Name the file the user will have, not the scratch copy.
      return e.message.replaceAll('${scratch.path}${p.separator}', '');
      // The manifest parser reports a bad value by throwing ArgumentError.
      // ignore: avoid_catching_errors
    } on ArgumentError catch (e) {
      return '${e.message}';
    } on FormatException catch (e) {
      return e.message;
    } finally {
      scratch.deleteSync(recursive: true);
    }
  }

  /// Writes [files] under [dir]. A file already there is replaced only when
  /// it carries [flatpakInitMarker]; the paths left alone are returned.
  Set<String> _write(Directory dir, Map<String, String> files) {
    final kept = <String>{};
    for (final entry in files.entries) {
      final file = File(p.join(dir.path, entry.key));
      if (file.existsSync() &&
          !file.readAsStringSync().contains(flatpakInitMarker)) {
        kept.add(entry.key);
        continue;
      }
      file
        ..createSync(recursive: true)
        ..writeAsStringSync(entry.value);
    }
    return kept;
  }

  /// The binary counterpart of [_write]: with no marker to look for, a file
  /// already there is replaced only while it is still byte-for-byte what emb
  /// would write.
  Set<String> _writeBinaries(Directory dir, Map<String, Uint8List> files) {
    final kept = <String>{};
    for (final entry in files.entries) {
      final file = File(p.join(dir.path, entry.key));
      if (file.existsSync()) {
        final existing = file.readAsBytesSync();
        final same =
            existing.length == entry.value.length &&
            Iterable<int>.generate(
              existing.length,
            ).every((i) => existing[i] == entry.value[i]);
        if (!same) kept.add(entry.key);
        continue;
      }
      file
        ..createSync(recursive: true)
        ..writeAsBytesSync(entry.value);
    }
    return kept;
  }

  _Pubspec? _readPubspec(Directory app) {
    final file = File(p.join(app.path, 'pubspec.yaml'));
    if (!file.existsSync()) return null;
    try {
      final doc = loadYaml(file.readAsStringSync());
      if (doc is! YamlMap) return null;
      final name = doc['name']?.toString();
      if (name == null || name.isEmpty) return null;
      final description = doc['description']?.toString().trim();
      return _Pubspec(
        name: name,
        // `1.2.3+4`: the build number means nothing to a package version.
        version: doc['version']?.toString().split('+').first,
        description: description == null || description.isEmpty
            ? null
            : description.split('\n').first,
      );
    } on YamlException {
      return null;
    }
  }
}

class _Pubspec {
  const _Pubspec({required this.name, this.version, this.description});

  final String name;
  final String? version;
  final String? description;
}
