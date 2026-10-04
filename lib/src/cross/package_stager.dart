import 'dart:convert';
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

  static final _safeName = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._+-]*$');
  static final _octalMode = RegExp(r'^[0-7]{3,4}$');

  /// A mode reaches `chmod` as an argument, so an option-shaped value is read
  /// as an option: `--reference=/etc/shadow` copied another file's bits, and
  /// the batched call applies one mode to many files at once. Octal only.
  void _checkMode(String mode) {
    if (!_octalMode.hasMatch(mode)) {
      fail('file mode must be 3-4 octal digits, got "$mode"');
    }
  }

  /// Stage [binary] at the absolute [installPath], plus [extraFiles] (host
  /// source → absolute target path), under `<outDir>/<packageName>.stage`
  /// (0755 on the binary). [fileModes] gives an octal mode per extra-file
  /// source (e.g. `0755`); a source absent from it keeps the copied file's
  /// mode. Returns the staging root — a tree rooted at the target's `/` — for
  /// the format's build step to consume.
  Future<Directory> stagePayload({
    required File binary,
    required String installPath,
    required String packageName,
    required Directory outDir,
    Map<String, String> extraFiles = const {},
    Map<String, String> fileModes = const {},
  }) async {
    if (!binary.existsSync()) fail('binary not found: ${binary.path}');
    if (!p.isAbsolute(installPath)) {
      fail('install path must be absolute: $installPath');
    }
    for (final dest in extraFiles.values) {
      if (!p.isAbsolute(dest)) fail('extra file dest must be absolute: $dest');
    }
    // `packageName` names a directory that is deleted recursively below, and
    // `p.join` drops its base when the next part is absolute — so `../../x` or
    // `/home/dev/proj` aimed both the staging and that delete at the
    // developer's own files.
    if (!_safeName.hasMatch(packageName)) {
      fail(
        'package name must match [A-Za-z0-9][A-Za-z0-9._+-]* — it names a '
        'staging directory, got "$packageName"',
      );
    }
    for (final mode in fileModes.values) {
      _checkMode(mode);
    }

    outDir.createSync(recursive: true);
    final root = Directory(p.join(outDir.path, '$packageName.stage'));
    if (root.existsSync()) root.deleteSync(recursive: true);

    /// Where [target] lands inside the staging root.
    ///
    /// `isAbsolute` alone was not enough. `/../../escaped` resolved outside the
    /// root, so the file survived the clean; and a `to:` of
    /// `/../<pkg>.stage/DEBIAN/postinst` normalized back *inside* the package,
    /// into the control dir, past the maintainer-script allowlist. A `..`
    /// segment has no legitimate use in an on-target path, so refuse it
    /// outright and keep the containment check as a backstop.
    String stagedPath(String target) {
      if (p.split(target).contains('..')) {
        fail('destination must not contain "..": $target');
      }
      final staged = p.normalize(p.join(root.path, target.substring(1)));
      if (!p.isWithin(root.path, staged)) {
        fail('destination escapes the staging root: $target');
      }
      return staged;
    }

    Future<void> chmod(String mode, List<String> paths) async {
      final result = await _run('chmod', ['--', mode, ...paths]);
      if (result.exitCode != 0) {
        fail('chmod failed (exit ${result.exitCode}): ${result.stderr.trim()}');
      }
    }

    // Install the binary at the requested path inside the staging root.
    final dest = File(stagedPath(installPath))
      ..parent.createSync(recursive: true);
    binary.copySync(dest.path);
    await chmod('0755', [dest.path]);

    // Repeated destinations must retain their original copy/chmod order.
    final seenDestinations = <String>{};
    final repeatedDestinations = <String>{};
    for (final target in extraFiles.values) {
      final staged = stagedPath(target);
      if (!seenDestinations.add(staged)) repeatedDestinations.add(staged);
    }

    // Stage extra files, collecting unique destinations by requested mode.
    final pathsByMode = <String, List<String>>{};
    for (final entry in extraFiles.entries) {
      final src = File(entry.key);
      if (!src.existsSync()) fail('extra file not found: ${entry.key}');
      final to = File(stagedPath(entry.value))
        ..parent.createSync(recursive: true);
      src.copySync(to.path);
      final mode = fileModes[entry.key];
      if (mode != null) {
        if (repeatedDestinations.contains(to.path)) {
          await chmod(mode, [to.path]);
        } else {
          pathsByMode.putIfAbsent(mode, () => []).add(to.path);
        }
      }
    }
    // Bound both the path count and argv bytes; hundreds of asset files should
    // not cause hundreds of processes or exceed a platform's argument limit.
    const maxPathsPerCall = 1024;
    const maxArgumentBytes = 96 * 1024;
    for (final entry in pathsByMode.entries) {
      final mode = entry.key;
      final initialArgumentBytes = 3 + utf8.encode(mode).length + 1;
      var paths = <String>[];
      var argumentBytes = initialArgumentBytes;
      for (final path in entry.value) {
        final pathBytes = utf8.encode(path).length + 1;
        if (paths.isNotEmpty &&
            (paths.length >= maxPathsPerCall ||
                argumentBytes + pathBytes > maxArgumentBytes)) {
          await chmod(mode, paths);
          paths = <String>[];
          argumentBytes = initialArgumentBytes;
        }
        paths.add(path);
        argumentBytes += pathBytes;
      }
      if (paths.isNotEmpty) await chmod(mode, paths);
    }
    return root;
  }
}
