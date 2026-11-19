import 'dart:io';

import 'package:emb_cli/src/cross/cross_project.dart';
import 'package:emb_cli/src/cross/cross_target.dart';
import 'package:emb_cli/src/manifest/source_repo.dart';
import 'package:emb_cli/src/repo/git_repo.dart';
import 'package:emb_cli/src/step_reporter.dart';
import 'package:emb_cli/src/workspace/workspace.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:path/path.dart' as p;

/// The workspace a manifest builds in: [override] (`-w`) → the manifest's
/// `workspace:` → `$FLUTTER_WORKSPACE` → cwd. The manifest beats the
/// environment on purpose, so a repo can pin where it builds regardless of the
/// calling shell.
///
/// `emb cross`, `emb fetch` and `emb doctor` share this, so what one clones
/// or fetches is where the others look.
Workspace resolveBuildWorkspace(
  CrossProject project, {
  String? override,
  Map<String, String>? environment,
  Logger? logger,
}) {
  final declared = project.workspaceDir;
  if (override == null && declared != null) {
    final env = (environment ?? Platform.environment)['FLUTTER_WORKSPACE'];
    if (env != null && env.isNotEmpty && p.normalize(env) != declared) {
      logger?.detail('  ignoring inherited FLUTTER_WORKSPACE=$env');
    }
    return Workspace(Directory(declared));
  }
  return Workspace.resolve(override: override);
}

/// Where [repo] is cloned in [workspace]: `<workspace>/app/<folder>`.
Directory sourceCheckoutDir(SourceRepo repo, Workspace workspace) => Directory(
  p.join(workspace.appDir.path, GitRepo.fromSource(repo).folderName),
);

/// Where the `cross.source` of each unresolved target is already cloned, by
/// target name: the `sourceDirs` to resolve [project] again with. Targets
/// with no source, or none cloned yet, are absent.
Map<String, String> clonedSources(CrossProject project, Workspace workspace) {
  final out = <String, String>{};
  for (final t in project.unresolved.values) {
    final repo = CrossTarget.repoFrom(t.block['source']);
    if (repo == null) continue;
    final dest = sourceCheckoutDir(repo, workspace);
    if (dest.existsSync()) out[t.name] = dest.path;
  }
  return out;
}

/// Clone or update a manifest-declared repo into `<workspace>/app`, or null
/// after reporting why it could not be had. Uses the same [GitRepo] machinery
/// as `emb sync`. [sourcePath] is the declaring manifest, which relative
/// `patches:` resolve against. [offline] reuses an existing checkout.
Future<Directory?> syncSourceRepo(
  SourceRepo repo,
  Workspace workspace, {
  required Logger logger,
  required String what,
  required String? sourcePath,
  required bool offline,
}) async {
  final git = GitRepo.fromSource(repo).resolvePatchesAgainst(sourcePath);
  final dest = Directory(p.join(workspace.appDir.path, git.folderName));
  if (offline) {
    if (dest.existsSync()) {
      logger.detail('  offline: reusing ${dest.path}');
      return dest;
    }
    logger.err(
      '  --offline cannot fetch the $what (${repo.uri}) — '
      'run once online, or clone it to ${dest.path} yourself.',
    );
    return null;
  }

  final progress = StepReporter(
    logger,
  ).start('Fetching $what (${git.folderName})');
  final result = await git.sync(
    workspace.ensureAppDir(),
    patchBase: sourcePath == null
        ? null
        : Directory(p.dirname(p.absolute(sourcePath))),
  );
  if (!result.success) {
    progress.fail('$what: ${result.message ?? "git failed"}');
    return null;
  }
  progress.complete('$what → ${dest.path}');
  return dest;
}
