import 'dart:io';

import 'package:emb_cli/src/repo/git_repo.dart';

/// Clones/updates many [GitRepo]s into a base folder with bounded concurrency.
///
/// The Python tool synced repositories strictly one at a time; emb overlaps
/// the network-bound clones/fetches up to [concurrency] at once.
class RepoSyncer {
  const RepoSyncer({this.concurrency = 4});

  /// Maximum number of git operations running at once.
  final int concurrency;

  /// Sync every repo in [repos] into [baseFolder]. Each repo's result is
  /// reported via [onResult] as it completes. Returns all results.
  ///
  /// [patchBase] is forwarded to [GitRepo.sync] as the directory relative
  /// patch paths resolve against — the directory holding the manifest.
  Future<List<RepoResult>> syncAll(
    List<GitRepo> repos,
    Directory baseFolder, {
    GitRunner runner = defaultGitRunner,
    void Function(RepoResult result)? onResult,
    Directory? patchBase,
  }) async {
    baseFolder.createSync(recursive: true);
    final results = <RepoResult>[];
    final iterator = repos.iterator;

    Future<void> worker() async {
      while (true) {
        final GitRepo repo;
        if (!iterator.moveNext()) break;
        repo = iterator.current;
        final result = await repo.sync(
          baseFolder,
          runner: runner,
          patchBase: patchBase,
        );
        results.add(result);
        onResult?.call(result);
      }
    }

    final workerCount = concurrency < 1 ? 1 : concurrency;
    await Future.wait(List.generate(workerCount, (_) => worker()));
    return results;
  }
}
