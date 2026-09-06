import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:emb_cli/src/init/flatpak_repo.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

/// {@template init_command}
/// `emb init` — scaffold a packaging repository.
///
/// A subcommand per package kind, so `emb init deb`/`init rpm` can follow the
/// same shape without claiming another top-level name.
/// {@endtemplate}
class InitCommand extends Command<int> {
  /// {@macro init_command}
  InitCommand({required Logger logger}) {
    addSubcommand(InitFlatpakCommand(logger: logger));
  }

  @override
  String get description => 'Scaffold a packaging repository for an app.';

  @override
  String get name => 'init';
}

/// `emb init flatpak <dir>` — a complete, buildable flatpak packaging repo.
///
/// Writes the manifest, build script, CI, pins and docs that `emb cross
/// --flatpak` needs, filled in from flags and (when `--app` is given) the
/// Flutter app's own `pubspec.yaml`. Nothing app-, vendor- or machine-specific
/// is baked in: the output is correct for an app the generator has never seen.
class InitFlatpakCommand extends Command<int> {
  /// Creates the command.
  InitFlatpakCommand({required Logger logger}) : _logger = logger {
    argParser
      ..addOption(
        'app-id',
        help:
            'Reverse-DNS flatpak application id, e.g. com.example.App. '
            'Required — it cannot be guessed safely.',
      )
      ..addOption(
        'app',
        help:
            'Flutter app directory. Its pubspec.yaml supplies the name, '
            'description and version unless overridden.',
      )
      ..addOption(
        'app-name',
        help:
            "Display name (default: the id's last "
            'segment, or the pubspec name).',
      )
      ..addOption(
        'app-version',
        help:
            'Package version (default: 1.0.0, or '
            'the pubspec version).',
      )
      ..addOption('summary', help: 'One-line AppStream summary.')
      ..addOption(
        'runtime-version',
        help: 'Flatpak runtime branch.',
        defaultsTo: '25.08',
      )
      ..addOption(
        'runtime',
        help: 'Flatpak runtime id.',
        defaultsTo: 'org.freedesktop.Platform',
      )
      ..addOption(
        'backend',
        help: 'Embedder backend to build.',
        defaultsTo: 'wayland-egl',
      )
      ..addOption(
        'embedder',
        help: 'Embedder project the app runs under.',
        defaultsTo: 'ivi-homescreen',
      )
      ..addOption('app-repo', help: 'owner/name of the app repo, for CI.')
      ..addOption('app-ref', help: 'Commit SHA of the app to build.')
      ..addOption(
        'homescreen-repo',
        help: 'Embedder repository URL.',
        defaultsTo: 'https://github.com/toyota-connected/ivi-homescreen',
      )
      ..addOption(
        'homescreen-ref',
        help: 'Embedder git ref.',
        defaultsTo: 'main',
      )
      ..addOption(
        'flutter-version',
        help: 'Flutter SDK version CI provisions.',
        defaultsTo: '3.44.2',
      )
      ..addOption('engine-version', help: 'Flutter engine commit, when pinned.')
      ..addOption(
        'emb-cli-ref',
        help: 'emb_cli ref CI bootstraps.',
        defaultsTo: 'main',
      )
      ..addOption('icon', help: 'PNG to ship as the app icon.')
      ..addFlag(
        'force',
        help: 'Overwrite existing files in a non-empty target directory.',
        negatable: false,
      );
  }

  final Logger _logger;

  @override
  String get description =>
      'Generate a flatpak packaging repo (manifest, build script, CI).';

  @override
  String get name => 'flatpak';

  @override
  String get invocation => 'emb init flatpak <target-dir> --app-id <id>';

  @override
  Future<int> run() async {
    final args = argResults!;
    final rest = args.rest;
    if (rest.length != 1) {
      _logger.err('Usage: $invocation');
      return ExitCode.usage.code;
    }

    final appId = args['app-id'] as String?;
    if (appId == null || appId.isEmpty) {
      _logger.err('--app-id is required (reverse-DNS, e.g. com.example.App).');
      return ExitCode.usage.code;
    }
    if (!flatpakAppIdPattern.hasMatch(appId)) {
      _logger.err(
        'Invalid --app-id "$appId": need reverse-DNS with at least three '
        'segments, e.g. com.example.App.',
      );
      return ExitCode.usage.code;
    }

    final target = Directory(p.absolute(rest.single));
    final force = args['force'] == true;
    if (target.existsSync() && target.listSync().isNotEmpty && !force) {
      _logger.err(
        '${target.path} is not empty. Pass --force to write into it anyway.',
      );
      return ExitCode.usage.code;
    }

    // An icon is copied, never invented: emitting a PNG from inline Dart is
    // exactly the kind of baked-in content this generator avoids.
    final iconPath = args['icon'] as String?;
    File? icon;
    if (iconPath != null && iconPath.isNotEmpty) {
      icon = File(iconPath);
      if (!icon.existsSync()) {
        _logger.err('--icon not found: $iconPath');
        return ExitCode.usage.code;
      }
    }

    final appDir = args['app'] as String?;
    final Map<String, String> pubspec;
    if (appDir == null || appDir.isEmpty) {
      pubspec = const {};
    } else {
      final dir = Directory(appDir);
      if (!dir.existsSync()) {
        _logger.err('--app directory does not exist: $appDir');
        return ExitCode.usage.code;
      }
      pubspec = _readPubspec(dir);
      if (pubspec.isEmpty) {
        _logger.warn(
          '  no readable pubspec.yaml in $appDir — falling back to defaults',
        );
      }
    }

    final spec = FlatpakRepoSpec(
      appId: appId,
      appName: (args['app-name'] as String?) ?? pubspec['name'],
      appVersion:
          (args['app-version'] as String?) ?? pubspec['version'] ?? '1.0.0',
      summary: (args['summary'] as String?) ?? pubspec['description'],
      description: pubspec['description'],
      runtime: args['runtime'] as String,
      runtimeVersion: args['runtime-version'] as String,
      backend: args['backend'] as String,
      embedder: args['embedder'] as String,
      appRepo: (args['app-repo'] as String?) ?? '',
      appRef: (args['app-ref'] as String?) ?? '',
      homescreenRepo: args['homescreen-repo'] as String,
      homescreenRef: args['homescreen-ref'] as String,
      flutterVersion: args['flutter-version'] as String,
      engineVersion: (args['engine-version'] as String?) ?? '',
      embCliRef: args['emb-cli-ref'] as String,
      hasIcon: icon != null,
    );

    final files = <String, String>{
      p.join('emb', spec.manifestName): generateEmbManifest(spec),
      p.join('emb', spec.appdataName): generateAppdata(spec),
      p.join('emb-src', '${spec.embedder}-src', 'emb.yaml'):
          generateEmbedderSrcManifest(spec),
      p.join('scripts', 'build.sh'): generateBuildScript(spec),
      p.join('.github', 'actions', 'build-embedder', 'action.yml'):
          generateBuildEmbedderAction(spec),
      p.join('.github', 'workflows', 'ci.yml'): generateCiWorkflow(spec),
      'versions.env': generateVersionsEnv(spec),
      '.gitignore': generateGitignore(),
      'README.md': generateReadme(spec),
    };

    for (final entry in files.entries) {
      final out = File(p.join(target.path, entry.key))
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(entry.value);
      // The build script is the one file that has to be executable; a repo
      // whose entry point needs `chmod +x` first is not finished.
      if (entry.key.endsWith('.sh')) _makeExecutable(out);
      _logger.info('  ${entry.key}');
    }
    if (icon != null) {
      icon.copySync(p.join(target.path, 'emb', spec.iconName));
      _logger.info('  ${p.join('emb', spec.iconName)}');
    }

    _logger
      ..info('')
      ..info('Generated ${spec.appName} packaging in ${target.path}')
      ..info('')
      ..info('Next:')
      ..info('  1. Fill in APP_REPO and APP_REF in versions.env')
      ..info(
        '  2. Widen finish_args in emb/${spec.manifestName} if the app '
        'needs more than a Wayland socket',
      )
      ..info('  3. APP_DIR=<flutter-app> ./scripts/build.sh')
      ..info(
        '     (clones ${spec.embedder} itself; set IHS_DIR for your own '
        'checkout)',
      );
    return ExitCode.success.code;
  }

  /// `name`, `description` and `version` from an app's `pubspec.yaml`, or an
  /// empty map when there is nothing readable there. Inference is a
  /// convenience, so a malformed pubspec degrades to defaults rather than
  /// failing the command.
  Map<String, String> _readPubspec(Directory appDir) {
    final file = File(p.join(appDir.path, 'pubspec.yaml'));
    if (!file.existsSync()) return const {};
    try {
      final doc = loadYaml(file.readAsStringSync());
      if (doc is! Map) return const {};
      return {
        for (final key in const ['name', 'description', 'version'])
          if (doc[key] != null) key: doc[key].toString().trim(),
      };
    } on Object {
      return const {};
    }
  }

  /// Set the owner/group/other execute bits, best-effort. A generated repo is
  /// still usable via `bash scripts/build.sh` if chmod is unavailable.
  void _makeExecutable(File file) {
    if (Platform.isWindows) return;
    try {
      Process.runSync('chmod', ['+x', file.path]);
    } on ProcessException {
      // Non-fatal: the file is written, just not marked executable.
    }
  }
}
