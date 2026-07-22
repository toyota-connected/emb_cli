import 'dart:io';

import 'package:emb_cli/src/manifest/source_repo.dart';
import 'package:emb_cli/src/repo/patch_series.dart';
import 'package:path/path.dart' as p;

/// Runs a git subcommand in [workingDirectory]. Injectable for testing.
typedef GitRunner =
    Future<ProcessResult> Function(
      List<String> args, {
      required String workingDirectory,
    });

/// Default [GitRunner] backed by `Process.run`.
Future<ProcessResult> defaultGitRunner(
  List<String> args, {
  required String workingDirectory,
}) => Process.run('git', args, workingDirectory: workingDirectory);

/// The outcome of syncing a single repository.
class RepoResult {
  const RepoResult({
    required this.folderName,
    required this.uri,
    required this.success,
    this.message,
  });

  final String folderName;
  final String uri;
  final bool success;
  final String? message;
}

/// A git repository that can be cloned/updated into a workspace `app/` folder.
///
/// Ports `get_repo`: clone when absent (after removing a stale non-git dir),
/// otherwise `reset --hard` + `fetch --all` + `pull --ff-only`; then checkout
/// the requested rev/branch and fetch LFS objects and submodules when present.
class GitRepo {
  const GitRepo({
    required this.uri,
    this.branch,
    this.rev,
    this.destName,
    this.patches = const [],
  });

  factory GitRepo.fromSource(SourceRepo s) => GitRepo(
    uri: s.uri,
    branch: s.branch,
    rev: s.rev,
    destName: s.destName,
    patches: s.patches,
  );

  final String uri;
  final String? branch;
  final String? rev;
  final String? destName;

  /// Patch files applied after checkout, in order. See [SourceRepo.patches].
  final List<String> patches;

  /// A copy of this repo whose relative [patches] are rewritten to resolve
  /// against the directory holding [declaringFile] — the manifest that
  /// declared them.
  ///
  /// Resolution happens here, at load time, rather than at apply time: a sync
  /// merges repos from several manifests (plus bare `repos.json` arrays) into
  /// one list, so there is no single base directory that is correct for all of
  /// them once they are pooled.
  ///
  /// Absolute patch paths, an empty [patches], or a null [declaringFile] all
  /// return the repo unchanged.
  GitRepo resolvePatchesAgainst(String? declaringFile) {
    if (patches.isEmpty || declaringFile == null) return this;
    final base = p.dirname(p.absolute(declaringFile));
    return GitRepo(
      uri: uri,
      branch: branch,
      rev: rev,
      destName: destName,
      patches: resolvePatchPaths(patches, base),
    );
  }

  /// Destination folder name. Mirrors the Python derivation
  /// `uri.rsplit('/',1)[-1].split('.')[0]`, unless [destName] overrides it.
  String get folderName {
    if (destName != null && destName!.isNotEmpty) return destName!;
    final last = uri.split('/').last;
    return last.split('.').first;
  }

  /// Clone or update this repo under [baseFolder].
  ///
  /// [patchBase] is the directory relative paths in [patches] resolve against —
  /// the directory holding the manifest that declared them. Ignored when
  /// [patches] is empty.
  Future<RepoResult> sync(
    Directory baseFolder, {
    GitRunner runner = defaultGitRunner,
    Directory? patchBase,
  }) async {
    final base = baseFolder.path;
    final gitFolder = p.join(base, folderName);
    final dotGit = Directory(p.join(gitFolder, '.git'));

    try {
      // `git clone` runs with cwd = base, so the base must exist first. emb
      // sync clones into <root>/app (ensured by the caller); emb flutter clones
      // straight into <root>, which may not exist yet for a fresh -w path.
      baseFolder.createSync(recursive: true);
      if (dotGit.existsSync()) {
        await _run(runner, ['reset', '--hard'], gitFolder);
        await _run(runner, ['fetch', '--all'], gitFolder);
        // pull is allowed to fail (e.g. detached / diverged) — warn, continue.
        final pullArgs = [
          'pull',
          '--ff-only',
          if (branch != null) ...['origin', branch!],
        ];
        await _run(runner, pullArgs, gitFolder, allowFailure: true);
      } else {
        if (Directory(gitFolder).existsSync()) {
          Directory(gitFolder).deleteSync(recursive: true);
        }
        await _run(runner, [
          'clone',
          uri,
          folderName,
          if (branch != null) ...['-b', branch!],
        ], base);
      }

      if (rev != null) {
        await _checkout(runner, rev!, gitFolder);
      } else if (branch != null) {
        await _checkout(runner, branch!, gitFolder);
      }

      if (File(p.join(gitFolder, '.gitattributes')).existsSync()) {
        await _run(
          runner,
          ['lfs', 'fetch', '--all'],
          gitFolder,
          allowFailure: true,
        );
      }
      if (File(p.join(gitFolder, '.gitmodules')).existsSync()) {
        await _run(runner, [
          'submodule',
          'update',
          '--init',
          '--recursive',
        ], gitFolder);
      }

      // Patches land last, on top of the requested rev and its submodules, so
      // a patch may touch submodule content too.
      if (patches.isNotEmpty) {
        await _applyPatches(runner, gitFolder, patchBase);
      }

      return RepoResult(folderName: folderName, uri: uri, success: true);
    } on _GitException catch (e) {
      return RepoResult(
        folderName: folderName,
        uri: uri,
        success: false,
        message: e.message,
      );
    } on ProcessException catch (e) {
      // git not installed / not on PATH (vs. a non-zero git exit, which
      // surfaces as a _GitException). Report it instead of crashing.
      return RepoResult(
        folderName: folderName,
        uri: uri,
        success: false,
        message: 'git could not be run: ${e.message}',
      );
    } on FileSystemException catch (e) {
      return RepoResult(
        folderName: folderName,
        uri: uri,
        success: false,
        message: 'workspace path unusable: ${e.message}',
      );
    }
  }

  /// Apply [patches] in order, resolving relative paths against [patchBase].
  ///
  /// Shares its implementation (and therefore its diagnostics) with the
  /// augment overlay's patch support; see applyPatchSeries.
  Future<void> _applyPatches(
    GitRunner runner,
    String gitFolder,
    Directory? patchBase,
  ) async {
    try {
      await applyPatchSeries(
        runner: runner,
        workDir: gitFolder,
        patches: resolvePatchPaths(
          patches,
          patchBase?.path ?? Directory.current.path,
        ),
        onto: rev ?? branch ?? 'the default branch',
        restore: () async {
          await _run(
            runner,
            ['reset', '--hard'],
            gitFolder,
            allowFailure: true,
          );
          await _run(runner, ['clean', '-fd'], gitFolder, allowFailure: true);
        },
      );
    } on PatchSeriesException catch (e) {
      throw _GitException(e.message);
    }
  }

  /// Check out [ref] (a branch, tag, or commit), tolerating a failing
  /// `post-checkout` hook.
  ///
  /// `post-checkout` runs *after* the worktree is updated, and per
  /// githooks(5) its exit status becomes the exit status of `git checkout`.
  /// So a hook that fails — e.g. Flutter's monorepo hooks call depot_tools'
  /// `vpython3`, which may be absent — makes the command report failure even
  /// though the checkout itself succeeded. Judge the result by HEAD instead:
  /// if it resolves to [ref]'s commit, the checkout landed and the hook's
  /// exit status is not a checkout failure.
  Future<void> _checkout(GitRunner runner, String ref, String cwd) async {
    final r = await runner(['checkout', ref], workingDirectory: cwd);
    if (r.exitCode == 0) return;
    if (await _headIsAt(runner, ref, cwd)) return;
    throw _GitException(
      'git checkout $ref failed (${r.exitCode}): ${r.stderr}',
    );
  }

  /// Whether HEAD now resolves to the same commit as [ref].
  Future<bool> _headIsAt(GitRunner runner, String ref, String cwd) async {
    final head = await runner(['rev-parse', 'HEAD'], workingDirectory: cwd);
    final target = await runner([
      'rev-parse',
      '$ref^{commit}',
    ], workingDirectory: cwd);
    if (head.exitCode != 0 || target.exitCode != 0) return false;
    final headSha = '${head.stdout}'.trim();
    final targetSha = '${target.stdout}'.trim();
    return headSha.isNotEmpty && headSha == targetSha;
  }

  Future<void> _run(
    GitRunner runner,
    List<String> args,
    String cwd, {
    bool allowFailure = false,
  }) async {
    final r = await runner(args, workingDirectory: cwd);
    if (r.exitCode != 0 && !allowFailure) {
      throw _GitException(
        'git ${args.join(" ")} failed (${r.exitCode}): ${r.stderr}',
      );
    }
  }
}

class _GitException implements Exception {
  _GitException(this.message);
  final String message;
}
