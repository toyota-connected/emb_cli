import 'dart:io';

import 'package:emb_cli/src/cross/process_runner.dart';
import 'package:path/path.dart' as p;

/// Shared payload-staging for every package format emitted from a cross build —
/// `.deb`, `.ipk`, and `.tar.gz`. It lays the cross-built binary and any extra
/// files into a staging root at their on-target paths; subclasses then turn
/// that tree into their format (a control archive, or a plain tarball).
///
/// Subclasses supply only [fail] (their typed exception); validation and the
/// file copying live here.
abstract class PackageStager {
  PackageStager(ProcessRunner run) : _run = run;

  final ProcessRunner _run;

  /// The process runner, exposed to subclasses for their build invocation.
  ProcessRunner get run => _run;

  /// Throw the format's typed exception, so callers' `catch` stays specific.
  Never fail(String message);

  /// Stage [binary] at the absolute [installPath], plus [extraFiles] (host
  /// source → absolute target path), under `<outDir>/<packageName>.stage`
  /// (0755 on the binary). Returns the staging root — a tree rooted at the
  /// target's `/` — for the format's build step to consume.
  Future<Directory> stagePayload({
    required File binary,
    required String installPath,
    required String packageName,
    required Directory outDir,
    Map<String, String> extraFiles = const {},
  }) async {
    if (!binary.existsSync()) fail('binary not found: ${binary.path}');
    if (!p.isAbsolute(installPath)) {
      fail('install path must be absolute: $installPath');
    }
    for (final dest in extraFiles.values) {
      if (!p.isAbsolute(dest)) fail('extra file dest must be absolute: $dest');
    }

    outDir.createSync(recursive: true);
    final root = Directory(p.join(outDir.path, '$packageName.stage'));
    if (root.existsSync()) root.deleteSync(recursive: true);

    // Install the binary at the requested path inside the staging root.
    final dest = File(p.join(root.path, installPath.substring(1)))
      ..parent.createSync(recursive: true);
    binary.copySync(dest.path);
    await _run('chmod', ['0755', dest.path]);

    // Stage any extra files at their absolute target paths inside the root.
    for (final entry in extraFiles.entries) {
      final src = File(entry.key);
      if (!src.existsSync()) fail('extra file not found: ${entry.key}');
      final to = File(p.join(root.path, entry.value.substring(1)))
        ..parent.createSync(recursive: true);
      src.copySync(to.path);
    }
    return root;
  }
}
