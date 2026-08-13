import 'dart:io';

import 'package:emb_cli/src/cache/store.dart';
import 'package:emb_cli/src/cross/apk_index.dart';
import 'package:emb_cli/src/cross/apk_sysroot.dart';
import 'package:path/path.dart' as p;

/// Real HTTP fetch + `tar` extraction backing [AlpineApkSysroot]. Fetches each
/// repo's `APKINDEX.tar.gz`, resolves the dependency closure, and materializes
/// the musl sysroot into the shared store. The pure resolution/keying/adopt
/// core lives in `apk_sysroot.dart` (injectable and unit-tested); this wires it
/// to the network and the filesystem.
class AlpineApkProvider {
  AlpineApkProvider({
    required Store store,
    HttpClient? http,
    Directory? workDir,
  }) : _store = store,
       _http = http ?? HttpClient(),
       _work = workDir ?? Directory.systemTemp.createTempSync('emb-apk-');

  final Store _store;
  final HttpClient _http;
  final Directory _work;

  /// Fetch + parse each repo index, resolve the closure, and materialize the
  /// sysroot into the store (a cache hit skips all network).
  Future<Directory> resolve(ApkSysrootSpec spec) async {
    final index = ApkIndex();
    for (final repo in spec.repos) {
      final base = spec.repoBase(repo);
      final archive = await _download('$base/APKINDEX.tar.gz');
      index.addAll(parseApkIndex(await _readMember(archive), repoBase: base));
    }
    final builder = AlpineApkSysroot(
      store: _store,
      fetch: _download,
      extract: _extractApk,
    );
    return builder.materialize(spec, index);
  }

  Future<File> _download(String url) async {
    final request = await _http.getUrl(Uri.parse(url));
    final response = await request.close();
    if (response.statusCode != 200) {
      throw HttpException('GET $url → ${response.statusCode}');
    }
    final file = File(p.join(_work.path, 'dl', _safeName(url)))
      ..createSync(recursive: true);
    await response.pipe(file.openWrite());
    return file;
  }

  /// Read the `APKINDEX` member out of an `APKINDEX.tar.gz`.
  Future<String> _readMember(File archive) async {
    final r = await Process.run('tar', [
      '-xzO',
      '-f',
      archive.path,
      'APKINDEX',
    ]);
    if (r.exitCode != 0) {
      throw ProcessException('tar', ['-xzO', archive.path], '${r.stderr}');
    }
    final out = r.stdout;
    return out is String ? out : '$out';
  }

  /// Extract an `.apk` (concatenated gzip streams) into [dest]. `tar` reads the
  /// file tree across the streams; the metadata dotfiles (`.PKGINFO`/`.SIGN…`)
  /// it also drops at the root are harmless in a sysroot.
  Future<void> _extractApk(File apk, Directory dest) async {
    final r = await Process.run('tar', ['-xzf', apk.path, '-C', dest.path]);
    // tar may exit non-zero on the signature member; tolerate it as long as a
    // real payload landed.
    if (r.exitCode != 0 &&
        !Directory(p.join(dest.path, 'usr')).existsSync() &&
        !Directory(p.join(dest.path, 'lib')).existsSync()) {
      throw ProcessException('tar', ['-xzf', apk.path], '${r.stderr}');
    }
  }

  String _safeName(String url) =>
      url.split('/').where((s) => s.isNotEmpty).last;

  /// Release the HTTP client.
  void close() => _http.close(force: true);
}
