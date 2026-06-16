import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:emb_cli/src/manifest/emb_manifest.dart';
import 'package:emb_cli/src/manifest/manifest_loader.dart';
import 'package:emb_cli/src/manifest/source_repo.dart';
import 'package:emb_cli/src/repo/git_repo.dart';
import 'package:emb_cli/src/repo/repo_syncer.dart';
import 'package:emb_cli/src/workspace/workspace.dart';
import 'package:mason_logger/mason_logger.dart';

/// {@template sync_command}
/// `emb sync` — clone/update all source repositories declared by the selected
/// manifests (and an optional `repos.json`) into `<workspace>/app`, with
/// bounded concurrency.
/// {@endtemplate}
class SyncCommand extends Command<int> {
  /// {@macro sync_command}
  SyncCommand({
    required Logger logger,
    ManifestLoader loader = const ManifestLoader(),
  }) : _logger = logger,
       _loader = loader {
    argParser
      ..addMultiOption(
        'config',
        abbr: 'c',
        help: 'Legacy JSON config directory (repeatable).',
        defaultsTo: const ['configs'],
      )
      ..addMultiOption(
        'packages',
        abbr: 'p',
        help: 'Directory to discover self-describing emb manifests.',
      )
      ..addMultiOption(
        'enable',
        help:
            'Force-load the config with this id (overrides load: false). '
            'Repeatable; ids that match nothing are ignored.',
      )
      ..addMultiOption(
        'disable',
        help:
            'Skip the config with this id (overrides load: true). '
            'Repeatable; ids that match nothing are ignored.',
      )
      ..addMultiOption(
        'repos',
        help:
            'A JSON file containing a bare array of repo entries '
            '(repeatable).',
      )
      ..addOption(
        'workspace',
        abbr: 'w',
        help: r'Workspace root (defaults to $FLUTTER_WORKSPACE or cwd).',
      )
      ..addOption(
        'concurrency',
        abbr: 'j',
        help: 'Maximum concurrent git operations.',
        defaultsTo: '4',
      );
  }

  final Logger _logger;
  final ManifestLoader _loader;

  @override
  String get description =>
      'Clone/update source repositories into <workspace>/app.';

  @override
  String get name => 'sync';

  @override
  Future<int> run() async {
    final args = argResults!;
    final workspace = Workspace.resolve(override: args['workspace'] as String?);

    // Collect repos from manifests' `src` lists.
    final raw = <EmbManifest>[];
    for (final dir in args['config'] as List<String>) {
      raw.addAll(_loader.loadConfigDir(Directory(dir)));
    }
    for (final dir in args['packages'] as List<String>) {
      raw.addAll(_loader.discoverPackages(Directory(dir)));
    }
    final manifests = _loader.select(
      raw,
      enable: (args['enable'] as List<String>).toSet(),
      disable: (args['disable'] as List<String>).toSet(),
    );

    final repos = <GitRepo>[];
    for (final m in manifests) {
      repos.addAll(m.src.map(GitRepo.fromSource));
    }
    // Plus any bare repos.json arrays.
    for (final path in args['repos'] as List<String>) {
      repos.addAll(_loadReposFile(File(path)));
    }

    // De-duplicate by destination folder name.
    final seen = <String>{};
    final unique = repos.where((r) => seen.add(r.folderName)).toList();

    if (unique.isEmpty) {
      _logger.warn('No source repositories found to sync.');
      return ExitCode.success.code;
    }

    final concurrency = int.tryParse(args['concurrency'] as String) ?? 4;
    final appDir = workspace.appDir;
    _logger
      ..info('Workspace: ${workspace.root.path}')
      ..info(
        'Syncing ${unique.length} repo(s) into ${appDir.path} '
        '(concurrency: $concurrency)',
      );

    final progress = _logger.progress('Syncing repositories');
    var done = 0;
    final results = await const RepoSyncer().syncAll(
      unique,
      appDir,
      onResult: (r) {
        done++;
        progress.update(
          '[$done/${unique.length}] ${r.folderName}'
          '${r.success ? "" : " FAILED"}',
        );
      },
    );

    final failed = results.where((r) => !r.success).toList();
    if (failed.isEmpty) {
      progress.complete('Synced ${results.length} repo(s)');
      return ExitCode.success.code;
    }
    progress.fail('${failed.length}/${results.length} repo(s) failed');
    for (final f in failed) {
      _logger.err('  ${f.folderName}: ${f.message}');
    }
    return ExitCode.software.code;
  }

  List<GitRepo> _loadReposFile(File file) {
    if (!file.existsSync()) {
      _logger.warn('repos file not found: ${file.path}');
      return const [];
    }
    try {
      final decoded = jsonDecode(file.readAsStringSync());
      if (decoded is! List) return const [];
      return decoded
          .whereType<Map<String, dynamic>>()
          .map(SourceRepo.fromMap)
          .map(GitRepo.fromSource)
          .toList();
    } on FormatException catch (e) {
      _logger.err('Failed to parse ${file.path}: $e');
      return const [];
    }
  }
}
