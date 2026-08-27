import 'dart:io';

import 'package:emb_cli/src/cross/elf_check.dart';
import 'package:path/path.dart' as p;

/// The shared objects emb always places in a bundle's `lib/` regardless of the
/// app: the AOT app image (absent in debug/JIT bundles) and the Flutter engine.
const _baseLibNames = {'libapp.so', 'libflutter_engine.so'};

/// The result of auditing a bundle's `lib/` directory.
class BundleLibAudit {
  const BundleLibAudit({required this.strays, required this.archMismatches});

  /// Basenames present in `lib/` that emb did not put there — the engine, the
  /// app image, and the declared module artifacts are the only allowed files.
  /// A stray `libstdc++`/`libssl` copied by a build script lands here: because
  /// bundle `lib/` is on the loader path, it would shadow the system copy
  /// process-wide and crash the embedder when an OS update shifts that copy.
  final List<String> strays;

  /// `"<name>: <reason>"` for each ELF whose header does not match the target,
  /// catching a host-arch engine, app image, or module that "built" fine.
  final List<String> archMismatches;

  bool get ok => strays.isEmpty && archMismatches.isEmpty;
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
  final strays = <String>[];
  final archMismatches = <String>[];
  if (!libDir.existsSync()) {
    return const BundleLibAudit(strays: [], archMismatches: []);
  }

  final sonames = {...moduleArtifacts, ...codeAssets};
  bool allowed(String name) =>
      _baseLibNames.contains(name) ||
      sonames.any((s) => name == s || name.startsWith('$s.'));

  for (final e in libDir.listSync(followLinks: false)) {
    final name = p.basename(e.path);
    if (!allowed(name)) strays.add(name);
    // Symlinks come back as Link (followLinks: false); the real file they point
    // at is a sibling File and is checked on its own iteration.
    if (e is File) {
      final reason = verifyElfForTriple(e, triple);
      if (reason != null) archMismatches.add('$name: $reason');
    }
  }
  strays.sort();
  archMismatches.sort();
  return BundleLibAudit(strays: strays, archMismatches: archMismatches);
}
