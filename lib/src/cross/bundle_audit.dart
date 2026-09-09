import 'dart:io';

import 'package:emb_cli/src/cross/elf_check.dart';
import 'package:path/path.dart' as p;

/// The shared objects emb always places in a bundle's `lib/` regardless of the
/// app: the AOT app image (absent in debug/JIT bundles) and the Flutter engine.
const _baseLibNames = {'libapp.so', 'libflutter_engine.so'};

/// One file in a bundle's `lib/` that should not ship as it stands.
///
/// A single file can be wrong in both ways at once — a host-built native asset
/// is typically an arch mismatch *and* something emb never placed — so the two
/// live together and are reported as one line rather than two unrelated
/// complaints about the same path.
class BundleLibProblem {
  const BundleLibProblem({
    required this.name,
    this.archReason,
    this.stray = false,
  });

  /// Basename within the bundle's `lib/`.
  final String name;

  /// Why the ELF header does not match the target, or null when it does.
  final String? archReason;

  /// Whether emb did not place this file: it is not the engine, the app image,
  /// a declared module artifact, or a staged code asset.
  final bool stray;

  /// A single line saying what is wrong with this file, leading with the
  /// architecture — the concrete, checkable fact — when there is one.
  String describe() {
    const strayWhy =
        'not the engine, the app image, or a declared module artifact — and '
        'bundle lib/ is on the loader path, so it would shadow the system '
        'copy at runtime';
    final why = <String>[
      if (archReason != null) archReason!,
      if (stray) strayWhy,
    ];
    return '$name: ${why.join('; ')}';
  }
}

/// The result of auditing a bundle's `lib/` directory.
class BundleLibAudit {
  const BundleLibAudit(this.problems);

  /// Every file that should not ship as it stands, sorted by name.
  final List<BundleLibProblem> problems;

  /// Basenames present in `lib/` that emb did not put there — the engine, the
  /// app image, and the declared module artifacts are the only allowed files.
  /// A stray `libstdc++`/`libssl` copied by a build script lands here: because
  /// bundle `lib/` is on the loader path, it would shadow the system copy
  /// process-wide and crash the embedder when an OS update shifts that copy.
  List<String> get strays => [
    for (final p in problems)
      if (p.stray) p.name,
  ];

  /// `"<name>: <reason>"` for each ELF whose header does not match the target,
  /// catching a host-arch engine, app image, or module that "built" fine.
  List<String> get archMismatches => [
    for (final p in problems)
      if (p.archReason != null) '${p.name}: ${p.archReason}',
  ];

  bool get ok => problems.isEmpty;
}

/// Audit [libDir] against what a bundle for [triple] may contain: the engine,
/// the app image, the [moduleArtifacts] declared by the build, and the
/// [codeAssets] the stager copied out of `flutter_assets/native_assets`
/// (matched by soname or a versioned/symlink alias, the same way the stager
/// names them). Every non-symlink ELF is additionally checked for the target
/// arch. A missing directory audits as clean.
///
/// [codeAssets] exists because the bundler puts those libraries in `lib/`
/// itself — the manifest resolves them by bare name, so they have to sit beside
/// the engine — and without naming them here the audit rejects files emb just
/// finished placing. They are not declared in a manifest: upstream Flutter
/// generates them from the build and records them in
/// `NativeAssetsManifest.json`, and a hand-written list would have to track
/// every dependency that happens to ship a build hook. The arch check still
/// applies to them, which is the part that matters — a host-built native asset
/// in a cross bundle is exactly the bug this audit exists to catch.
BundleLibAudit auditBundleLib(
  Directory libDir, {
  required String triple,
  required Iterable<String> moduleArtifacts,
  Iterable<String> codeAssets = const [],
}) {
  final problems = <BundleLibProblem>[];
  if (!libDir.existsSync()) return const BundleLibAudit([]);

  final sonames = {...moduleArtifacts, ...codeAssets};
  bool allowed(String name) =>
      _baseLibNames.contains(name) ||
      sonames.any((s) => name == s || name.startsWith('$s.'));

  for (final e in libDir.listSync(followLinks: false)) {
    final name = p.basename(e.path);
    final stray = !allowed(name);
    // Symlinks come back as Link (followLinks: false); the real file they point
    // at is a sibling File and is checked on its own iteration.
    final reason = e is File ? verifyElfForTriple(e, triple) : null;
    if (stray || reason != null) {
      problems.add(
        BundleLibProblem(name: name, archReason: reason, stray: stray),
      );
    }
  }
  problems.sort((a, b) => a.name.compareTo(b.name));
  return BundleLibAudit(problems);
}
