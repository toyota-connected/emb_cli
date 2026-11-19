import 'dart:io';

import 'package:emb_cli/src/cross/process_runner.dart';
import 'package:path/path.dart' as p;

/// Combines a cross-built embedder binary with an assembled Flutter app bundle
/// into one runnable tree:
///
/// ```text
/// <dir>/
///   homescreen                       # the cross-built embedder
///   data/flutter_assets/ …
///   data/icudtl.dat
///   lib/libapp.so                    # AOT app (profile/release)
///   lib/libflutter_engine.so         # target-arch engine
/// ```
///
/// Run on the target as `./homescreen -b <dir>`. The `data/` + `lib/` halves
/// come from the bundle pipeline; this just drops the embedder in beside them.
class RunnableBundle {
  RunnableBundle({ProcessRunner runProcess = defaultProcessRunner})
    : _run = runProcess;

  final ProcessRunner _run;

  /// Copy [embedder] into [bundleDir] (which already holds `data/` + `lib/`),
  /// preserving the executable bit. Returns the installed binary.
  Future<File> install(File embedder, Directory bundleDir) async {
    if (!embedder.existsSync()) {
      throw RunnableBundleException('embedder not found: ${embedder.path}');
    }
    if (!Directory(p.join(bundleDir.path, 'data')).existsSync()) {
      throw RunnableBundleException(
        'no Flutter bundle in ${bundleDir.path} (missing data/)',
      );
    }
    final dest = File(p.join(bundleDir.path, p.basename(embedder.path)));
    try {
      embedder.copySync(dest.path);
    } on FileSystemException catch (e) {
      throw RunnableBundleException(
        'cannot copy ${embedder.path} to ${dest.path}: ${_reason(e)}',
      );
    }
    await _run('chmod', ['0755', dest.path]);
    return dest;
  }

  /// Replace [dst] with a copy of [src]'s contents, symlinks and modes
  /// preserved (`cp -a`).
  ///
  /// A full disk, a quota, or an unwritable build root all land here, so every
  /// failure is a [RunnableBundleException] naming both ends.
  Future<void> stage(Directory src, Directory dst) async {
    final what = 'cannot copy ${src.path} to ${dst.path}';
    try {
      if (dst.existsSync()) dst.deleteSync(recursive: true);
      dst.createSync(recursive: true);
    } on FileSystemException catch (e) {
      throw RunnableBundleException('$what: ${_reason(e)}');
    }
    final RunResult r;
    try {
      r = await _run('cp', ['-a', '.', dst.path], workingDirectory: src.path);
    } on ProcessException catch (e) {
      throw RunnableBundleException('$what: ${e.message}');
    }
    if (r.exitCode != 0) {
      throw RunnableBundleException('$what: ${r.stderr.trim()}');
    }
  }

  static String _reason(FileSystemException e) =>
      e.osError?.message ?? e.message;

  /// `tar -czf <dir>.tar.gz` the runnable tree; returns the archive.
  Future<File> tar(Directory dir) async {
    final out = File('${dir.path}.tar.gz');
    final r = await _run('tar', [
      '-czf',
      out.path,
      '-C',
      dir.parent.path,
      p.basename(dir.path),
    ]);
    if (r.exitCode != 0) {
      throw RunnableBundleException('tar failed: ${r.stderr}');
    }
    return out;
  }
}

/// Thrown when assembling or archiving a runnable bundle fails.
class RunnableBundleException implements Exception {
  RunnableBundleException(this.message);
  final String message;
  @override
  String toString() => 'RunnableBundleException: $message';
}
