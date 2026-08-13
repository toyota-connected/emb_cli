import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

/// Runs a git subcommand in [workingDirectory]. Injectable for testing.
typedef PatchRunner =
    Future<ProcessResult> Function(
      List<String> args, {
      required String workingDirectory,
    });

/// A patch series failed to apply. Carries an operator-facing explanation.
class PatchSeriesException implements Exception {
  PatchSeriesException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Resolve [patches] against [baseDir], leaving absolute entries alone.
List<String> resolvePatchPaths(List<String> patches, String baseDir) => [
  for (final patch in patches)
    if (p.isAbsolute(patch)) patch else p.normalize(p.join(baseDir, patch)),
];

/// A digest over a patch series' *contents*, for cache keys and stamps.
///
/// Covers each patch's basename and bytes, in order, so reordering or editing
/// a patch in place changes the digest even though its path did not. Anything
/// keyed on a source revision alone would go stale the moment a patch is
/// edited, silently reusing a tree built from the previous version.
///
/// A patch that cannot be read contributes a `missing` marker rather than
/// throwing, so a digest can still be computed for diagnostics.
String patchSeriesDigest(List<String> resolvedPatches) {
  final buffer = BytesBuilder(copy: false);
  for (final patch in resolvedPatches) {
    // NUL-separated, so a basename can never forge a name/content
    // boundary (a NUL cannot occur in one). Written as an escape
    // rather than a raw byte, which would make this file binary to git.
    buffer.add(utf8.encode('${p.basename(patch)}\u0000'));
    final file = File(patch);
    buffer.add(
      file.existsSync() ? file.readAsBytesSync() : utf8.encode('<missing>'),
    );
  }
  return sha256.convert(buffer.takeBytes()).toString();
}

/// Apply [patches] to the tree at [workDir], in order.
///
/// [patches] must already be absolute (see [resolvePatchPaths]). [onto]
/// describes what the series is applied on top of — a revision, a tarball
/// version — and appears in failure messages, where version skew is the most
/// common cause.
///
/// Every file is verified to exist before the first is applied, so a typo in a
/// manifest fails before the tree is touched rather than halfway through.
///
/// On failure [restore] is invoked, if given, to return the tree to a known
/// state, and a [PatchSeriesException] is thrown. Leaving a half-patched tree
/// would be worse than failing: it generally still builds, silently producing
/// something that does not match the manifest.
///
/// `git apply` operates on files and does not require [workDir] to be a git
/// repository, so this serves both a checkout and an unpacked tarball.
///
/// It is invoked with `--git-dir` pointed at a path that does not exist, which
/// forces the no-repository mode where patch paths resolve against [workDir].
/// Without it, a [workDir] that happens to sit inside some *other* repository
/// -- an unpacked tarball under a workspace directory inside the project repo,
/// say -- makes git resolve paths against that repository's root instead,
/// report `Skipped patch ...` for every file, and exit 0. The series would
/// then be recorded as applied while the tree was never touched.
Future<void> applyPatchSeries({
  required PatchRunner runner,
  required String workDir,
  required List<String> patches,
  required String onto,
  Future<void> Function()? restore,
}) async {
  if (patches.isEmpty) return;

  final missing = patches.where((f) => !File(f).existsSync()).toList();
  if (missing.isNotEmpty) {
    throw PatchSeriesException(
      'patch file(s) declared by the manifest do not exist:\n'
      '${missing.map((f) => "    $f").join("\n")}\n'
      '  Paths are resolved relative to the manifest that declared them.',
    );
  }

  for (var i = 0; i < patches.length; i++) {
    final patch = patches[i];
    final position = 'patch ${i + 1}/${patches.length}';

    // --check first: it reports the same diagnostics as a real apply but
    // touches nothing, so a failure here leaves the tree exactly as the
    // previous patch left it rather than partially rewritten.
    final check = await runner([
      _noRepo(workDir),
      'apply',
      '--check',
      '--verbose',
      patch,
    ], workingDirectory: workDir);
    if (check.exitCode != 0) {
      await restore?.call();
      throw PatchSeriesException(
        _failure(position, patch, onto, check, i, 'It does not apply here.'),
      );
    }

    final apply = await runner([
      _noRepo(workDir),
      'apply',
      patch,
    ], workingDirectory: workDir);
    if (apply.exitCode != 0) {
      await restore?.call();
      throw PatchSeriesException(
        _failure(
          position,
          patch,
          onto,
          apply,
          i,
          'It passed --check but failed to apply.',
        ),
      );
    }
  }
}

/// A `--git-dir` argument naming a path that cannot exist, forcing `git apply`
/// out of repository-discovery mode. See [applyPatchSeries].
String _noRepo(String workDir) =>
    '--git-dir=${p.join(workDir, '.emb-no-repo')}';

/// The operator-facing explanation of a patch failure: which patch, where it
/// lives, what it was applied onto, what git said, and the likeliest cause.
String _failure(
  String position,
  String patch,
  String onto,
  ProcessResult result,
  int index,
  String summary,
) {
  // git apply --verbose splits its report across both streams; taking only
  // stderr drops the "Checking patch ..." context that names the file.
  final detail = [
    '${result.stderr}'.trim(),
    '${result.stdout}'.trim(),
  ].where((s) => s.isNotEmpty).join('\n');
  final applied = index == 0
      ? 'none (this was the first patch)'
      : '$index patch(es) before it';
  final said = detail.isEmpty
      ? '      (git produced no output)'
      : detail.split('\n').map((l) => '      $l').join('\n');
  return '$position failed: ${p.basename(patch)}\n'
      '    $summary (git exit ${result.exitCode})\n'
      '    patch   : $patch\n'
      '    applied : onto $onto, after $applied\n'
      '    git said:\n'
      '$said\n'
      '    The tree was reset, so nothing is half-patched.\n'
      '    Most often this means the patch was authored against a different\n'
      '    revision than "$onto", or an earlier patch in the series already\n'
      '    changed the same lines.';
}
