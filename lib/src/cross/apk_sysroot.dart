import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:emb_cli/src/cache/store.dart';
import 'package:emb_cli/src/cross/apk_index.dart';

/// Fetch a URL to a local file (an `APKINDEX.tar.gz` or a `.apk`), injectable
/// for tests and offline reuse.
typedef ApkFetch = Future<File> Function(String url);

/// Extract a `.apk` (a gzip tar) into [dest], injectable for tests.
typedef ApkExtract = Future<void> Function(File apk, Directory dest);

/// The inputs that identify an Alpine musl sysroot.
class ApkSysrootSpec {
  const ApkSysrootSpec({
    required this.arch,
    required this.devPackages,
    this.mirror = 'https://dl-cdn.alpinelinux.org/alpine',
    this.branch = 'edge',
    this.repos = const ['main', 'community'],
  });

  /// apk arch token: `aarch64` | `x86_64` | `armv7` | `riscv64`.
  final String arch;
  final List<String> devPackages;
  final String mirror;

  /// `edge` | `v3.20` | …
  final String branch;
  final List<String> repos;

  String repoBase(String repo) => '$mirror/$branch/$repo/$arch';

  List<String> indexUrls() => [
    for (final r in repos) '${repoBase(r)}/APKINDEX.tar.gz',
  ];
}

/// A resolved download plan: the [packages] to fetch + a content key.
class ApkSysrootPlan {
  ApkSysrootPlan(this.spec, this.packages);

  final ApkSysrootSpec spec;
  final List<ApkPackage> packages;

  List<String> get urls => [for (final p in packages) p.url];

  /// Content-addressed key over branch, arch, and the resolved name=version set
  /// (order-independent) — the same closure reuses the store entry, a changed
  /// package set re-keys.
  String get key {
    final ids = [for (final p in packages) '${p.name}=${p.version}']..sort();
    final digest = sha256.convert(
      utf8.encode('alpine|${spec.branch}|${spec.arch}|${ids.join(",")}'),
    );
    return 'alpine-${spec.branch}-${spec.arch}-'
        '${digest.toString().substring(0, 16)}';
  }
}

/// Builds a root-free Alpine (musl) `-dev` sysroot from `apk` packages — the
/// musl analog of the Debian dpkg-deb path. Resolves the dependency closure
/// from a (merged) [ApkIndex] and stages it in the shared store, keyed by the
/// resolved package set. Downloads/extraction are injected.
/// (alpine-musl).
class AlpineApkSysroot {
  AlpineApkSysroot({
    required Store store,
    required ApkFetch fetch,
    required ApkExtract extract,
  }) : _store = store,
       _fetch = fetch,
       _extract = extract;

  final Store _store;
  final ApkFetch _fetch;
  final ApkExtract _extract;

  static const String kind = 'sysroot-base';

  /// Resolve the download plan for [spec] against [index].
  ApkSysrootPlan plan(ApkSysrootSpec spec, ApkIndex index) =>
      ApkSysrootPlan(spec, index.closure(spec.devPackages));

  /// Materialize the sysroot into the shared store and return its root. A cache
  /// hit (same resolved package set) returns the stored tree without fetching.
  Future<Directory> materialize(ApkSysrootSpec spec, ApkIndex index) async {
    final resolved = plan(spec, index);
    final cached = _store.rootOf(kind, resolved.key);
    if (cached.existsSync()) return cached;

    final dest = Directory.systemTemp.createTempSync('emb-apk-sysroot-');
    for (final pkg in resolved.packages) {
      final apk = await _fetch(pkg.url);
      await _extract(apk, dest);
    }
    return _store.adopt(kind: kind, key: resolved.key, existingDir: dest);
  }
}
