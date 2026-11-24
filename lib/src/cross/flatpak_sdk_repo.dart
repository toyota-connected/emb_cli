import 'dart:async';
import 'dart:convert';
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

/// What [FlatpakSdkRepo.gc] removed, or would have.
class SdkGcReport {
  const SdkGcReport(this.removed, this.objects);

  /// Refs and checkouts, one line each.
  final List<String> removed;

  /// ostree's own summary of the object prune (`Deleted 3 objects, 300.2 kB
  /// freed`), or null when there was no repo.
  final String? objects;
}

/// A flatpak ref checked out of an ostree repo: `files/` and `metadata`, the
/// same shape `flatpak info --show-location` points at.
class RepoCheckout {
  const RepoCheckout(this.path, this.commit, {this.warning});

  /// The checkout directory.
  final String path;

  /// The commit it holds, 64 hex characters.
  final String commit;

  /// Set when the pull failed and the cached commit was used instead.
  final String? warning;
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
    required TimedProcessRunner runProcess,
    this.offline = false,
    this.pullTimeout = defaultPullTimeout,
  }) : _run = runProcess;

  /// `<cache>/flatpak-sdk`.
  final Directory cacheDir;
  final TimedProcessRunner _run;

  /// The longest a pull may take before it is killed.
  final Duration pullTimeout;

  /// A backstop, not a stall detector: with libcurl, ostree already aborts a
  /// transfer below 1000 B/s for 30 s and retries it. This catches what that
  /// does not: older ostree, its other HTTP backend, a hung local filesystem.
  /// An SDK and its runtime are about a gigabyte, so it is generous.
  static const defaultPullTimeout = Duration(minutes: 30);

  /// When true, nothing is pulled: a ref must already be in the cache.
  final bool offline;

  String get _repo => p.join(cacheDir.path, 'repo');

  static var _partials = 0;

  /// Check out [ref] (`runtime/<id>/<arch>/<branch>`) from [source], a URL or
  /// an absolute path. With [gpgKey], its commits and its summary must be
  /// signed by that key, and a URL may not move [ref] to an older commit
  /// than the cache has.
  ///
  /// The summary is what maps a ref to a commit. With only commits signed,
  /// whoever serves [source] can point [ref] at any commit the key ever
  /// signed: last year's SDK, or another branch's. A signed summary stops a
  /// remap; it does not stop a replay of an old signed summary, which the
  /// timestamp check does. `pull-local` has no timestamp check, so for a
  /// local path emb compares the two commits' dates itself (#371).
  ///
  /// Holds the cache's lock shared, so builds run side by side and [gc]
  /// waits for them: it never deletes a ref a pull is updating, or a
  /// checkout a build is about to use.
  Future<RepoCheckout> checkout(
    String source,
    String ref, {
    String? gpgKey,
  }) => _locked(
    FileLock.blockingShared,
    () => _checkout(source, ref, gpgKey: gpgKey),
  );

  Future<RepoCheckout> _checkout(
    String source,
    String ref, {
    String? gpgKey,
  }) async {
    final local = !source.contains('://');
    // The key's bytes, not its path: it is imported only when the remote is
    // created, so a key rotated in place must name a new remote, or the old
    // keyring would go on judging commits.
    final remote = 'emb-${contentHash([source, _keyDigest(gpgKey)])}';
    await _configLocked(() async {
      await _ensureRepo();
      await _ensureRemote(remote, local ? 'file://$source' : source, gpgKey);
    });
    String? warning;
    if (!offline) {
      final before = local && gpgKey != null
          ? await _revParse(remote, ref)
          : null;
      final r = await _ostree(
        local
            ? [
                'pull-local',
                '--remote=$remote',
                if (gpgKey != null) ...['--gpg-verify', '--gpg-verify-summary'],
                source,
                ref,
              ]
            : ['pull', if (gpgKey != null) '--timestamp-check', remote, ref],
        timeout: pullTimeout,
      );
      if (r.exitCode != 0) {
        final why = r.exitCode == timedOutExitCode
            ? 'timed out after ${_span(pullTimeout)}'
            : _firstLine(r.stderr);
        // Not a network blip: the source served something the key does not
        // vouch for, or went back in time. Building on from the cache would
        // hide that for as long as it lasted.
        final refused = _refusal(r.stderr, source, ref);
        if (refused != null) throw FlatpakSdkRepoException(refused);
        // A commit this source served before, verified then if a key was
        // set. A network blip should not stop a build the cache can do.
        final cached = await _revParse(remote, ref);
        if (cached == null) {
          throw FlatpakSdkRepoException(
            'could not pull $ref from $source: $why',
          );
        }
        warning =
            'could not pull $ref from $source ($why); building with the '
            'cached commit ${cached.substring(0, 12)}, which may be stale';
      } else if (before != null) {
        await _refuseLocalRollback(remote, ref, source, before);
      }
    }
    final commit = await _revParse(remote, ref);
    if (commit == null) {
      throw FlatpakSdkRepoException(
        offline
            ? '$ref from $source is not in the cache, and --offline forbids '
                  'pulling it. Run `emb fetch` online first'
            : '$ref is not in $source',
      );
    }
    _stamp(commit);
    return RepoCheckout(
      await _checkoutCommit(commit),
      commit,
      warning: warning,
    );
  }

  /// Reclaim what no build has used within [safetyWindow], as `Store.gc`
  /// does for the rest of the cache:
  ///
  /// - a ref whose commit was last checked out before the window, so its
  ///   objects can go; a later build pulls it again;
  /// - a checkout last used before the window;
  /// - a partial checkout whose process is gone;
  /// - then every object no remaining ref's commit needs. An SDK update
  ///   leaves the old commit's objects behind, a gigabyte a time.
  ///
  /// A commit with no use recorded (pulled before emb recorded them) is
  /// recorded now and kept, so nothing goes on its first [gc].
  Future<SdkGcReport> gc({
    bool dryRun = false,
    Duration safetyWindow = const Duration(days: 7),
  }) async {
    if (!File(p.join(_repo, 'config')).existsSync()) {
      return const SdkGcReport([], null);
    }
    return _locked(FileLock.blockingExclusive, () async {
      final removed = <String>[];
      bool stale(String commit) =>
          _staleStamp(commit, safetyWindow, record: !dryRun);

      final refs = await _ostree(['refs']);
      if (refs.exitCode != 0) {
        throw FlatpakSdkRepoException(
          'could not list the refs in $_repo: ${_firstLine(refs.stderr)}',
        );
      }
      final kept = <String>{};
      for (final line in const LineSplitter().convert(refs.stdout)) {
        final colon = line.indexOf(':');
        if (!line.startsWith('emb-') || colon < 0) continue;
        final remote = line.substring(0, colon);
        final ref = line.substring(colon + 1);
        final head = await _revParse(remote, ref);
        if (head == null) continue;
        if (!stale(head)) {
          kept.add(head);
          continue;
        }
        if (!dryRun) {
          final r = await _ostree(['refs', '--delete', line]);
          if (r.exitCode != 0) {
            throw FlatpakSdkRepoException(
              'could not delete $line: ${_firstLine(r.stderr)}',
            );
          }
        }
        removed.add('flatpak-sdk ref $ref (${_source(remote)})');
      }

      final checkouts = Directory(p.join(cacheDir.path, 'checkouts'));
      if (checkouts.existsSync()) {
        for (final e in checkouts.listSync().whereType<Directory>()) {
          final name = p.basename(e.path);
          final partial = RegExp(
            r'^[0-9a-f]{64}\.partial-(\d+)-',
          ).firstMatch(name);
          final remove = partial != null
              ? !Directory('/proc/${partial[1]}').existsSync()
              : _commit.hasMatch(name) && !kept.contains(name) && stale(name);
          if (!remove) continue;
          if (!dryRun) e.deleteSync(recursive: true);
          removed.add('flatpak-sdk checkout ${name.substring(0, 12)}');
        }
      }

      // A use recorded for a commit with nothing left to use is noise.
      final used = Directory(p.join(cacheDir.path, 'used'));
      if (!dryRun && used.existsSync()) {
        for (final f in used.listSync().whereType<File>()) {
          final c = p.basename(f.path);
          if (!kept.contains(c) &&
              !Directory(p.join(checkouts.path, c)).existsSync()) {
            f.deleteSync();
          }
        }
      }

      final prune = await _ostree([
        'prune',
        '--refs-only',
        '--depth=0',
        if (dryRun) '--no-prune',
      ]);
      if (prune.exitCode != 0) {
        throw FlatpakSdkRepoException(
          'could not prune $_repo: ${_firstLine(prune.stderr)}',
        );
      }
      final lines = const LineSplitter()
          .convert(prune.stdout)
          .where((l) => l.trim().isNotEmpty);
      return SdkGcReport(removed, lines.isEmpty ? null : lines.last.trim());
    });
  }

  static final _commit = RegExp(r'^[0-9a-f]{64}$');

  File _stampOf(String commit) => File(p.join(cacheDir.path, 'used', commit));

  /// Record that a build used [commit] now.
  void _stamp(String commit) {
    try {
      _stampOf(commit)
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(DateTime.now().toUtc().toIso8601String());
    } on FileSystemException {
      // A missed record only makes gc keep the commit a while longer.
    }
  }

  /// Whether [commit] was last used before [window]. With no use recorded it
  /// is not; with [record], now is recorded as its use.
  bool _staleStamp(String commit, Duration window, {required bool record}) {
    final f = _stampOf(commit);
    final DateTime? at;
    try {
      at = f.existsSync()
          ? DateTime.tryParse(f.readAsStringSync().trim())
          : null;
    } on FileSystemException {
      return false;
    }
    if (at == null) {
      if (record) _stamp(commit);
      return false;
    }
    return DateTime.now().toUtc().difference(at.toUtc()) > window;
  }

  /// The URL or path behind [remote], for a report; [remote] itself if
  /// ostree cannot say.
  String _source(String remote) =>
      _remoteValue(remote, 'url')?.replaceFirst('file://', '') ?? remote;

  /// [key] from [remote]'s section of the repo config, or null.
  String? _remoteValue(String remote, String key) {
    try {
      final config = File(p.join(_repo, 'config')).readAsLinesSync();
      final at = config.indexOf('[remote "$remote"]');
      if (at < 0) return null;
      final pattern = RegExp('^${RegExp.escape(key)}\\s*=\\s*(.*)\$');
      for (final l in config.skip(at + 1)) {
        if (l.startsWith('[')) break;
        final m = pattern.firstMatch(l.trim());
        if (m != null) return m[1];
      }
    } on FileSystemException {
      // Fall through.
    }
    return null;
  }

  /// Why a failed pull must not fall back to the cache, from ostree's
  /// [stderr]; null for a failure the cache can ride out.
  static String? _refusal(String stderr, String source, String ref) {
    if (stderr.contains('chronologically older')) return _rollback(source, ref);
    if (stderr.contains('no summary found') ||
        stderr.contains('no summary.sig found')) {
      return '$source has no summary signed by sdk_repo_gpg_key. With a key '
          'set, emb requires one: it is what ties $ref to a commit. Sign it '
          'with `flatpak build-update-repo --gpg-sign=<key>` or '
          '`ostree summary -u --gpg-sign=<key>`';
    }
    if (stderr.contains('GPG') || stderr.contains('signature')) {
      return '$ref from $source is not signed by sdk_repo_gpg_key: '
          '${_firstLine(stderr)}';
    }
    return null;
  }

  static String _rollback(String source, String ref) =>
      '$source moved $ref to a commit older than the one cached; refusing '
      'the rollback. If it was rolled back on purpose, delete the '
      'flatpak-sdk cache to accept it';

  /// What `pull --timestamp-check` does, for `pull-local`, which has no such
  /// option: when the pull moved [ref] from [before] to an older commit, put
  /// it back and refuse. Equal dates pass, as they do there.
  Future<void> _refuseLocalRollback(
    String remote,
    String ref,
    String source,
    String before,
  ) async {
    final after = await _revParse(remote, ref);
    if (after == null || after == before) return;
    if (!(await _commitDate(after)).isBefore(await _commitDate(before))) {
      return;
    }
    final reset = await _ostree([
      'refs',
      '--create=$remote:$ref',
      '--force',
      before,
    ]);
    if (reset.exitCode != 0) {
      throw FlatpakSdkRepoException(
        '${_rollback(source, ref)}. The cache now holds the older commit, '
        'and putting back ${before.substring(0, 12)} failed: '
        '${_firstLine(reset.stderr)}',
      );
    }
    throw FlatpakSdkRepoException(_rollback(source, ref));
  }

  /// [commit]'s date, from `ostree show`, which prints it in UTC to the
  /// second: the commit's own resolution.
  Future<DateTime> _commitDate(String commit) async {
    final r = await _ostree(['show', commit]);
    final m = RegExp(
      r'^Date:\s+(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d) \+0000$',
      multiLine: true,
    ).firstMatch(r.stdout);
    final date = m == null ? null : DateTime.tryParse('${m[1]}Z');
    if (r.exitCode != 0 || date == null) {
      throw FlatpakSdkRepoException(
        'cannot read the date of commit ${commit.substring(0, 12)}, so '
        'cannot rule out a rollback: ${_firstLine(r.stderr)}',
      );
    }
    return date;
  }

  /// Run [body] holding `<cacheDir>/lock` as [mode]: shared for builds,
  /// exclusive for [gc].
  Future<T> _locked<T>(FileLock mode, Future<T> Function() body) async {
    cacheDir.createSync(recursive: true);
    final raf = File(p.join(cacheDir.path, 'lock')).openSync(
      mode: FileMode.append,
    );
    try {
      await raf.lock(mode);
      return await body();
    } finally {
      await raf.close();
    }
  }

  /// Run [body] alone among everything that changes `repo/config` (#369).
  ///
  /// `ostree init`, `remote add` and `config set` each read the whole config
  /// and write it back, so two at once can lose one's change: a remote gone,
  /// or a summary check never set. Builds hold the cache's lock shared, so it
  /// does not order them. This has its own lock, `config.lock`, rather than
  /// taking that one exclusive, which would wait behind another build's pull.
  ///
  /// The file lock orders processes. A process's own locks do not exclude
  /// each other, so builds within one are queued here first.
  Future<T> _configLocked<T>(Future<T> Function() body) async {
    cacheDir.createSync(recursive: true);
    final key = cacheDir.absolute.path;
    final before = _configQueue[key] ?? Future<void>.value();
    final mine = Completer<void>();
    _configQueue[key] = mine.future;
    try {
      await before;
      final raf = File(p.join(cacheDir.path, 'config.lock')).openSync(
        mode: FileMode.append,
      );
      try {
        await raf.lock(FileLock.blockingExclusive);
        return await body();
      } finally {
        await raf.close();
      }
    } finally {
      mine.complete();
      // The last in the queue clears it. The removed future has completed.
      if (identical(_configQueue[key], mine.future)) {
        unawaited(_configQueue.remove(key));
      }
    }
  }

  static final _configQueue = <String, Future<void>>{};

  /// The commit [remote] last gave for [ref] in the cache, or null.
  Future<String?> _revParse(String remote, String ref) async {
    final rev = await _ostree(['rev-parse', '$remote:$ref']);
    final commit = rev.stdout.trim();
    return rev.exitCode == 0 && RegExp(r'^[0-9a-f]{64}$').hasMatch(commit)
        ? commit
        : null;
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
      if (gpgKey != null) ...[
        '--gpg-import=$gpgKey',
        '--set=gpg-verify-summary=true',
      ] else
        '--no-gpg-verify',
      name,
      url,
    ]);
    if (r.exitCode != 0) {
      throw FlatpakSdkRepoException(
        'could not add $url to the ostree cache: ${_firstLine(r.stderr)}',
      );
    }
    // A remote added before emb verified summaries keeps its name, since the
    // key is the same, and so its cached commits for --offline. Bring it up
    // to date rather than re-pull under a new one.
    if (gpgKey == null || _remoteValue(name, 'gpg-verify-summary') == 'true') {
      return;
    }
    final set = await _ostree([
      'config',
      'set',
      'remote "$name".gpg-verify-summary',
      'true',
    ]);
    if (set.exitCode != 0) {
      throw FlatpakSdkRepoException(
        'could not require a signed summary from $url: '
        '${_firstLine(set.stderr)}',
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

  Future<RunResult> _ostree(List<String> args, {Duration? timeout}) async {
    try {
      return await _run('ostree', ['--repo=$_repo', ...args], timeout: timeout);
    } on ProcessException catch (e) {
      throw FlatpakSdkRepoException('could not run ostree: ${e.message}');
    }
  }

  static String _span(Duration d) =>
      d.inMinutes > 0 ? '${d.inMinutes} min' : '${d.inSeconds} s';

  static String _firstLine(String s) {
    final t = s.trim();
    final i = t.indexOf('\n');
    return i < 0 ? t : t.substring(0, i);
  }
}
