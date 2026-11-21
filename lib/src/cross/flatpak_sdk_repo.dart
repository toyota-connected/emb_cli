import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:emb_cli/src/cross/cross_keys.dart' show contentHash;
import 'package:emb_cli/src/cross/process_runner.dart';
import 'package:path/path.dart' as p;

/// Failure to get a ref out of an ostree repo, with what to do about it.
class FlatpakSdkRepoException implements Exception {
  const FlatpakSdkRepoException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// A flatpak ref checked out of an ostree repo: `files/` and `metadata`, the
/// same shape `flatpak info --show-location` points at.
class RepoCheckout {
  const RepoCheckout(this.path, this.commit);

  /// The checkout directory.
  final String path;

  /// The commit it holds, 64 hex characters.
  final String commit;
}

/// Pulls flatpak refs from an ostree repo into a cache and checks them out,
/// so an SDK can be built against without `flatpak install`: a Yocto build's
/// `repo-dev`, or an SDK for another architecture.
///
/// One `bare-user` repo under [cacheDir] holds everything pulled, so refs that
/// share objects (an SDK and its runtime, two commits of one SDK) share disk.
/// Checkouts go to `checkouts/<commit>` as hard links into that repo, take no
/// extra space, and are reused while the commit is unchanged.
///
/// Each source repo gets its own ostree remote, named from a hash of its
/// location and key, so refs from two repos never overwrite each other and a
/// later `--offline` run reads back exactly what this source served.
class FlatpakSdkRepo {
  FlatpakSdkRepo(
    this.cacheDir, {
    required ProcessRunner runProcess,
    this.offline = false,
  }) : _run = runProcess;

  /// `<cache>/flatpak-sdk`.
  final Directory cacheDir;
  final ProcessRunner _run;

  /// When true, nothing is pulled: a ref must already be in the cache.
  final bool offline;

  String get _repo => p.join(cacheDir.path, 'repo');

  static var _partials = 0;

  /// Check out [ref] (`runtime/<id>/<arch>/<branch>`) from [source], a URL or
  /// an absolute path. With [gpgKey], its commits must be signed by that key.
  Future<RepoCheckout> checkout(
    String source,
    String ref, {
    String? gpgKey,
  }) async {
    final local = !source.contains('://');
    // The key's bytes, not its path: it is imported only when the remote is
    // created, so a key rotated in place must name a new remote, or the old
    // keyring would go on judging commits.
    final remote = 'emb-${contentHash([source, _keyDigest(gpgKey)])}';
    await _ensureRepo();
    await _ensureRemote(remote, local ? 'file://$source' : source, gpgKey);
    if (!offline) {
      final r = local
          ? await _ostree([
              'pull-local',
              '--remote=$remote',
              if (gpgKey != null) '--gpg-verify',
              source,
              ref,
            ])
          : await _ostree(['pull', remote, ref]);
      if (r.exitCode != 0) {
        throw FlatpakSdkRepoException(
          'could not pull $ref from $source: ${_firstLine(r.stderr)}',
        );
      }
    }
    final rev = await _ostree(['rev-parse', '$remote:$ref']);
    final commit = rev.stdout.trim();
    if (rev.exitCode != 0 || !RegExp(r'^[0-9a-f]{64}$').hasMatch(commit)) {
      throw FlatpakSdkRepoException(
        offline
            ? '$ref from $source is not in the cache, and --offline forbids '
                  'pulling it. Run `emb fetch` online first'
            : '$ref is not in $source',
      );
    }
    return RepoCheckout(await _checkoutCommit(commit), commit);
  }

  static String _keyDigest(String? gpgKey) {
    if (gpgKey == null) return '';
    try {
      return sha256.convert(File(gpgKey).readAsBytesSync()).toString();
    } on FileSystemException catch (e) {
      throw FlatpakSdkRepoException(
        'cannot read sdk_repo_gpg_key $gpgKey: '
        '${e.osError?.message ?? e.message}',
      );
    }
  }

  Future<void> _ensureRepo() async {
    if (File(p.join(_repo, 'config')).existsSync()) return;
    cacheDir.createSync(recursive: true);
    final r = await _ostree(['init', '--mode=bare-user']);
    if (r.exitCode != 0) {
      throw FlatpakSdkRepoException(
        'could not create the ostree cache at $_repo: ${_firstLine(r.stderr)}',
      );
    }
  }

  Future<void> _ensureRemote(String name, String url, String? gpgKey) async {
    final r = await _ostree([
      'remote',
      'add',
      '--if-not-exists',
      if (gpgKey != null) '--gpg-import=$gpgKey' else '--no-gpg-verify',
      name,
      url,
    ]);
    if (r.exitCode != 0) {
      throw FlatpakSdkRepoException(
        'could not add $url to the ostree cache: ${_firstLine(r.stderr)}',
      );
    }
  }

  /// Check [commit] out once, into a temporary dir renamed into place, so an
  /// interrupted checkout is never mistaken for a finished one.
  ///
  /// The temporary dir is this process's own, so two emb runs checking out
  /// the same commit cannot delete each other's work; the second to finish
  /// finds the first one's checkout in place and drops its own.
  Future<String> _checkoutCommit(String commit) async {
    final dest = Directory(p.join(cacheDir.path, 'checkouts', commit));
    if (dest.existsSync()) return dest.path;
    dest.parent.createSync(recursive: true);
    _dropStalePartials(dest);
    // pid for other processes, a counter for this one: two checkouts started
    // in the same microsecond would otherwise share a name.
    final tmp = Directory('${dest.path}.partial-$pid-${_partials++}');
    final r = await _ostree(['checkout', '-U', commit, tmp.path]);
    if (r.exitCode != 0) {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
      throw FlatpakSdkRepoException(
        'could not check out $commit: ${_firstLine(r.stderr)}',
      );
    }
    try {
      tmp.renameSync(dest.path);
    } on FileSystemException {
      if (!dest.existsSync()) rethrow;
      tmp.deleteSync(recursive: true);
    }
    return dest.path;
  }

  /// Remove what a run killed mid-checkout left beside [dest]: a partial
  /// whose process is gone.
  ///
  /// Not by age: `ostree checkout` stamps what it writes with the epoch, so a
  /// checkout in progress looks decades old.
  static void _dropStalePartials(Directory dest) {
    final prefix = '${p.basename(dest.path)}.partial-';
    try {
      for (final e in dest.parent.listSync()) {
        final name = p.basename(e.path);
        if (e is! Directory || !name.startsWith(prefix)) continue;
        final owner = int.tryParse(
          name.substring(prefix.length).split('-').first,
        );
        if (owner == null || owner == pid) continue;
        if (!Directory('/proc/$owner').existsSync()) {
          e.deleteSync(recursive: true);
        }
      }
    } on FileSystemException {
      // Another run removed it first, or it cannot be read: not this run's.
    }
  }

  Future<RunResult> _ostree(List<String> args) async {
    try {
      return await _run('ostree', ['--repo=$_repo', ...args]);
    } on ProcessException catch (e) {
      throw FlatpakSdkRepoException('could not run ostree: ${e.message}');
    }
  }

  static String _firstLine(String s) {
    final t = s.trim();
    final i = t.indexOf('\n');
    return i < 0 ? t : t.substring(0, i);
  }
}
