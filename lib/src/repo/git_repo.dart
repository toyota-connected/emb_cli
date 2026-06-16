import 'dart:io';

import 'package:emb_cli/src/manifest/source_repo.dart';
import 'package:path/path.dart' as p;

/// Runs a git subcommand in [workingDirectory]. Injectable for testing.
typedef GitRunner = Future<ProcessResult> Function(
  List<String> args, {
  required String workingDirectory,
});

/// Default [GitRunner] backed by `Process.run`.
Future<ProcessResult> defaultGitRunner(
  List<String> args, {
  required String workingDirectory,
}) =>
    Process.run('git', args, workingDirectory: workingDirectory);

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
  });

  factory GitRepo.fromSource(SourceRepo s) => GitRepo(
        uri: s.uri,
        branch: s.branch,
        rev: s.rev,
        destName: s.destName,
      );

  final String uri;
  final String? branch;
  final String? rev;
  final String? destName;

  /// Destination folder name. Mirrors the Python derivation
  /// `uri.rsplit('/',1)[-1].split('.')[0]`, unless [destName] overrides it.
  String get folderName {
    if (destName != null && destName!.isNotEmpty) return destName!;
    final last = uri.split('/').last;
    return last.split('.').first;
  }

  /// Clone or update this repo under [baseFolder].
  Future<RepoResult> sync(
    Directory baseFolder, {
    GitRunner runner = defaultGitRunner,
  }) async {
    final base = baseFolder.path;
    final gitFolder = p.join(base, folderName);
    final dotGit = Directory(p.join(gitFolder, '.git'));

    try {
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
        await _run(
          runner,
          ['clone', uri, folderName, if (branch != null) ...['-b', branch!]],
          base,
        );
      }

      if (rev != null) {
        await _run(runner, ['checkout', rev!], gitFolder);
      } else if (branch != null) {
        await _run(runner, ['checkout', branch!], gitFolder);
      }

      if (File(p.join(gitFolder, '.gitattributes')).existsSync()) {
        await _run(runner, ['lfs', 'fetch', '--all'], gitFolder,
            allowFailure: true);
      }
      if (File(p.join(gitFolder, '.gitmodules')).existsSync()) {
        await _run(
          runner,
          ['submodule', 'update', '--init', '--recursive'],
          gitFolder,
        );
      }

      return RepoResult(folderName: folderName, uri: uri, success: true);
    } on _GitException catch (e) {
      return RepoResult(
        folderName: folderName,
        uri: uri,
        success: false,
        message: e.message,
      );
    }
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
          'git ${args.join(" ")} failed (${r.exitCode}): ${r.stderr}');
    }
  }
}

class _GitException implements Exception {
  _GitException(this.message);
  final String message;
}
