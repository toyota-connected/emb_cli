import 'dart:io';

import 'package:crypto/crypto.dart';
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
  EngineArtifacts(this.workspace, {HttpClient? httpClient})
      : _http = httpClient ?? HttpClient();

  final Workspace workspace;
  final HttpClient _http;

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
  Future<EngineFetchResult> fetch({
    required String runtime,
    required String arch,
    required String commit,
    bool clean = false,
  }) async {
    final url = engineSdkUrl(runtime, arch, commit);
    final filename = p.basename(Uri.parse(url).path);
    final engineDir = workspace.ensurePlatformDir('flutter-engine');
    final cwdEngine = Directory(p.join(engineDir.path, commit))
      ..createSync(recursive: true);
    final archiveFile = File(p.join(cwdEngine.path, filename));
    final sha256File = File('${archiveFile.path}.sha256');
    final bundleDir =
        Directory(p.join(engineDir.path, 'bundle-$runtime-$arch'));

    // Download unless a verified copy already exists.
    if (!_sha256Matches(archiveFile, sha256File)) {
      final ok = await _download(url, archiveFile);
      if (!ok) {
        return EngineFetchResult(
          runtime: runtime,
          arch: arch,
          status: EngineFetchStatus.unavailable,
          url: url,
          message: 'No published prebuilt for $runtime/$arch@$commit',
        );
      }
      sha256File.writeAsStringSync(_sha256OfFile(archiveFile));
    } else if (bundleDir.existsSync() && !clean) {
      return EngineFetchResult(
        runtime: runtime,
        arch: arch,
        status: EngineFetchStatus.upToDate,
        url: url,
        bundleDir: bundleDir.path,
      );
    }

    // Extract.
    final restoreDir = Directory(
        p.join(cwdEngine.path, 'engine-sdk-$runtime-$arch'))
      ..createSync(recursive: true);
    final tar = await Process.run(
      'tar',
      ['-xzf', archiveFile.path, '-C', restoreDir.path],
    );
    if (tar.exitCode != 0) {
      return EngineFetchResult(
        runtime: runtime,
        arch: arch,
        status: EngineFetchStatus.failed,
        url: url,
        message: 'tar extraction failed: ${tar.stderr}',
      );
    }

    // Stage the bundle layout: bundle-<runtime>-<arch>/{data,lib}.
    if (clean && bundleDir.existsSync()) {
      bundleDir.deleteSync(recursive: true);
    }
    final dataDir = Directory(p.join(bundleDir.path, 'data'))
      ..createSync(recursive: true);
    final libDir = Directory(p.join(bundleDir.path, 'lib'))
      ..createSync(recursive: true);

    // The archive nests the artifacts under
    // `[flutter/engine/]src/out/linux_<runtime>_<token>/engine-sdk/...`, where
    // <token> is the Flutter arch token (x64), not the release token (x86_64),
    // and the mono-repo prefix varies. Locate them by name rather than guessing
    // the path — there is exactly one of each in the archive.
    final icu = _findFile(restoreDir, 'icudtl.dat');
    final lib = _findFile(restoreDir, 'libflutter_engine.so');
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

  Future<bool> _download(String url, File dest) async {
    try {
      final req = await _http.getUrl(Uri.parse(url));
      req.followRedirects = true;
      final resp = await req.close();
      if (resp.statusCode != 200) {
        await resp.drain<void>();
        return false;
      }
      final sink = dest.openWrite();
      await resp.pipe(sink);
      return true;
    } on Object {
      return false;
    }
  }

  bool _sha256Matches(File archive, File sha256File) {
    if (!archive.existsSync() || !sha256File.existsSync()) return false;
    final expected = sha256File.readAsStringSync().replaceAll('\n', '').trim();
    return _sha256OfFile(archive) == expected;
  }

  String _sha256OfFile(File f) =>
      sha256.convert(f.readAsBytesSync()).toString();
}
