import 'dart:io';

import 'package:emb_cli/src/cache/cache_dir.dart';
import 'package:emb_cli/src/cache/cas.dart';
import 'package:emb_cli/src/cache/store.dart';
import 'package:emb_cli/src/host/host_info.dart';
import 'package:emb_cli/src/workspace/workspace.dart';
import 'package:path/path.dart' as p;

/// Flutter engine runtime modes whose prebuilt artifacts are published.
const engineRuntimeModes = ['release', 'profile', 'debug'];

/// Outcome of an engine artifact fetch.
enum EngineFetchStatus {
  /// Artifact downloaded (or already cached) and staged into the bundle.
  fetched,

  /// Artifact already staged and up to date; nothing downloaded.
  upToDate,

  /// No published prebuilt matched (would require a source build).
  unavailable,

  /// Download or extraction failed.
  failed,
}

/// Result of fetching one runtime mode.
class EngineFetchResult {
  const EngineFetchResult({
    required this.runtime,
    required this.arch,
    required this.status,
    this.url,
    this.bundleDir,
    this.message,
  });

  final String runtime;
  final String arch;
  final EngineFetchStatus status;
  final String? url;
  final String? bundleDir;
  final String? message;

  bool get ok =>
      status == EngineFetchStatus.fetched ||
      status == EngineFetchStatus.upToDate;
}

/// Fetches prebuilt Flutter engine artifacts from the `meta-flutter/flutter-engine`
/// GitHub releases, falling back to a source build when none is published.
///
/// Ports `get_engine_sdk_url` / `get_flutter_engine_artifacts`: build the
/// release URL from the engine commit + runtime + arch, download, verify, and
/// stage `icudtl.dat` + `libflutter_engine.so` into a `bundle-<runtime>-<arch>`
/// layout.
class EngineArtifacts {
  EngineArtifacts(
    this.workspace, {
    HttpClient? httpClient,
    Cas? cas,
    Store? store,
  }) : _http = httpClient ?? HttpClient(),
       _casOverride = cas,
       _storeOverride = store;

  final Workspace workspace;
  final HttpClient _http;

  final Cas? _casOverride;
  final Store? _storeOverride;

  /// Content-addressed download cache and extracted-tree store, rooted at the
  /// shared cache dir. Built lazily; injectable for tests.
  late final Cas _cas =
      _casOverride ?? Cas(ensureCacheDir(), httpClient: _http);
  late final Store _store = _storeOverride ?? Store(ensureCacheDir());

  static const _releaseBase =
      'https://github.com/meta-flutter/flutter-engine/releases/download';

  /// Normalize any host/Flutter arch token to the engine-artifact arch token
  /// used by the published `meta-flutter/flutter-engine` releases:
  /// `x86_64`, `arm64`, `armv7hf`, `riscv64`.
  ///
  /// Accepts both raw machine arch (`x86_64`, `aarch64`, `riscv64`, …) and
  /// Flutter tokens (`x64`, `arm64`, `arm`). Extends `get_engine_sdk_url`,
  /// which only handled `x64`/`arm`.
  static String engineArch(String arch) {
    switch (arch.toLowerCase()) {
      case 'x64':
      case 'x86_64':
      case 'amd64':
        return 'x86_64';
      case 'arm':
      case 'armv7':
      case 'armv7hf':
      case 'armhf':
        return 'armv7hf';
      case 'arm64':
      case 'aarch64':
        return 'arm64';
      case 'riscv64':
        return 'riscv64';
      default:
        return arch;
    }
  }

  /// The engine-artifact arch token for [host]'s machine architecture — the
  /// "proper engine SDK" to fetch on this machine.
  static String engineArchForHost(HostInfo host) =>
      engineArch(host.machineArch);

  /// File written into a staged bundle recording which engine artifact it came
  /// from, so a later build can tell a current bundle from a stale one.
  static const bundleStampName = '.emb-engine-key';

  /// Identity of one engine artifact: the same key the shared store uses.
  static String engineKey(String runtime, String arch, String commit) =>
      '$commit-${engineArch(arch)}-$runtime';

  /// Build the engine SDK tarball URL for [runtime]/[arch]/[commit].
  static String engineSdkUrl(String runtime, String arch, String commit) {
    final a = engineArch(arch);
    final stem = 'linux-engine-sdk-$runtime-$a-$commit';
    return '$_releaseBase/$stem/$stem.tar.gz';
  }

  /// Whether a prebuilt for [runtime]/[arch]/[commit] is published (HTTP HEAD,
  /// following redirects).
  Future<bool> isAvailable(String runtime, String arch, String commit) async {
    final url = engineSdkUrl(runtime, arch, commit);
    try {
      final req = await _http.headUrl(Uri.parse(url));
      req.followRedirects = true;
      final resp = await req.close();
      await resp.drain<void>();
      return resp.statusCode == 200;
    } on Object {
      return false;
    }
  }

  /// Fetch and stage the engine artifact for one [runtime] mode.
  ///
  /// The extracted engine SDK is sourced from the shared store (downloaded once
  /// per machine, keyed by `(commit, arch, runtime)`) and symlinked into the
  /// per-workspace `flutter-engine/<commit>/engine-sdk-<runtime>-<arch>` so
  /// gen_snapshot resolution is unchanged. The tiny `bundle-<runtime>-<arch>`
  /// (`icudtl.dat` + `libflutter_engine.so`) is staged per workspace from the
  /// store tree.
  Future<EngineFetchResult> fetch({
    required String runtime,
    required String arch,
    required String commit,
    bool clean = false,
  }) async {
    final url = engineSdkUrl(runtime, arch, commit);
    final engineDir = workspace.ensurePlatformDir('flutter-engine');
    final cwdEngine = Directory(p.join(engineDir.path, commit))
      ..createSync(recursive: true);
    // Normalized arch token, matching what BundleBuilder looks for. Built from
    // the raw `arch` this staged `bundle-release-x64` alongside the
    // `bundle-release-x86_64` the consumer reads -- two directories for one
    // artifact, and only one of them ever consulted.
    final bundleDir = Directory(
      p.join(engineDir.path, 'bundle-$runtime-${engineArch(arch)}'),
    );
    final restoreLink = p.join(cwdEngine.path, 'engine-sdk-$runtime-$arch');
    final key = engineKey(runtime, arch, commit);

    // Ensure the extracted engine SDK is in the shared store, then symlink the
    // per-workspace path to it (preserving the clang_<host>/bin↔lib64 sibling
    // layout gen_snapshot walks).
    final Directory storeRoot;
    try {
      storeRoot = await _store.ensure(
        kind: 'engine',
        key: key,
        sourceUrl: url,
        fetch: () => _cas.ensure(url),
        stage: (blob, into) async {
          final r = await _store.run('tar', [
            '-xzf',
            blob.path,
            '-C',
            into.path,
          ]);
          if (r.exitCode != 0) {
            throw StateError('engine extract failed: ${r.stderr}');
          }
        },
      );
    } on Object {
      return EngineFetchResult(
        runtime: runtime,
        arch: arch,
        status: EngineFetchStatus.unavailable,
        url: url,
        message: 'No published prebuilt for $runtime/$arch@$commit',
      );
    }
    _store.materialize(kind: 'engine', key: key, linkPath: restoreLink);

    // The bundle is staged per (runtime, arch) while the engine SDK beside
    // it is staged per (commit, runtime, arch), so "the directory exists" is
    // not enough to call it current: after an engine commit bump gen_snapshot
    // moves to the new commit and an unstamped bundle keeps serving the old
    // libflutter_engine.so. The AOT snapshot and the engine then disagree --
    // "snapshot requires 'release' ... but the VM has 'product'" -- with
    // nothing in the build output to say why. Stamp what was staged and restage
    // when it no longer matches.
    final stamp = File(p.join(bundleDir.path, bundleStampName));
    final staged = stamp.existsSync() ? stamp.readAsStringSync().trim() : '';
    if (bundleDir.existsSync() && !clean && staged == key) {
      return EngineFetchResult(
        runtime: runtime,
        arch: arch,
        status: EngineFetchStatus.upToDate,
        url: url,
        bundleDir: bundleDir.path,
      );
    }

    // Stage the bundle layout: bundle-<runtime>-<arch>/{data,lib}, sourced from
    // the store tree. The archive nests the two artifacts under a variable
    // `…/engine-sdk/…` prefix, so locate them by name (exactly one of each).
    if (bundleDir.existsSync()) bundleDir.deleteSync(recursive: true);
    final dataDir = Directory(p.join(bundleDir.path, 'data'))
      ..createSync(recursive: true);
    final libDir = Directory(p.join(bundleDir.path, 'lib'))
      ..createSync(recursive: true);
    final icu = _findFile(storeRoot, 'icudtl.dat');
    final lib = _findFile(storeRoot, 'libflutter_engine.so');
    if (icu == null || lib == null) {
      return EngineFetchResult(
        runtime: runtime,
        arch: arch,
        status: EngineFetchStatus.failed,
        url: url,
        message: 'Engine artifacts not found in extracted archive',
      );
    }
    icu.copySync(p.join(dataDir.path, 'icudtl.dat'));
    lib.copySync(p.join(libDir.path, 'libflutter_engine.so'));
    stamp.writeAsStringSync(key);

    return EngineFetchResult(
      runtime: runtime,
      arch: arch,
      status: EngineFetchStatus.fetched,
      url: url,
      bundleDir: bundleDir.path,
    );
  }

  /// Close the underlying HTTP client.
  void close() => _http.close(force: true);

  /// Recursively find the first file named [name] under [root].
  File? _findFile(Directory root, String name) {
    for (final e in root.listSync(recursive: true, followLinks: false)) {
      if (e is File && p.basename(e.path) == name) return e;
    }
    return null;
  }
}
