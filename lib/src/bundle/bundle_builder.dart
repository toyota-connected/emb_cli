import 'dart:io';

import 'package:emb_cli/src/engine/engine_artifacts.dart';
import 'package:emb_cli/src/workspace/workspace.dart';
import 'package:path/path.dart' as p;

/// Outcome of assembling an ivi-homescreen bundle.
class BundleResult {
  const BundleResult({
    required this.success,
    this.outputDir,
    this.missing = const [],
    this.message,
  });

  final bool success;

  /// The assembled bundle directory, on success.
  final String? outputDir;

  /// Human-readable descriptions of missing inputs, on failure.
  final List<String> missing;

  final String? message;
}

/// Assembles the bundle layout consumed by `ivi-homescreen`:
///
/// ```text
/// <output>/
///   data/flutter_assets/        # from `flutter build bundle`
///   data/icudtl.dat             # from the engine bundle
///   lib/libapp.so               # the AOT image for <mode>
///   lib/libflutter_engine.so    # from the engine bundle
/// ```
///
/// Combines the app half (`<app>/build/flutter_assets` + `<app>/libapp.so.<mode>`
/// produced by `emb aot`) with the engine half staged by `emb engine`
/// (`bundle-<mode>-<token>/{data/icudtl.dat,lib/libflutter_engine.so}`).
class BundleBuilder {
  const BundleBuilder(this.workspace);

  final Workspace workspace;

  /// The engine bundle directory staged by `emb engine` for [mode]/[arch].
  Directory engineBundleDir(String mode, String arch) => Directory(
    p.join(
      workspace.platformDir('flutter-engine').path,
      'bundle-$mode-${EngineArtifacts.engineArch(arch)}',
    ),
  );

  /// Assemble the bundle for the app at [appPath] into [outputDir].
  BundleResult assemble({
    required String appPath,
    required String mode,
    required String arch,
    required String outputDir,
  }) {
    // debug is JIT — the app runs from kernel_blob.bin in flutter_assets, so
    // there is no AOT libapp.so. profile/release are AOT and require it.
    final isDebug = mode == 'debug';
    final app = p.absolute(appPath);
    final assets = Directory(p.join(app, 'build', 'flutter_assets'));
    final libapp = File(p.join(app, 'libapp.so.$mode'));
    final engineDir = engineBundleDir(mode, arch);
    final icu = File(p.join(engineDir.path, 'data', 'icudtl.dat'));
    final engineSo = File(
      p.join(engineDir.path, 'lib', 'libflutter_engine.so'),
    );

    final missing = <String>[
      if (!assets.existsSync())
        'flutter_assets — run `emb bundle --build` (or flutter build bundle)',
      if (!isDebug && !libapp.existsSync())
        'libapp.so.$mode — run `emb aot --mode $mode`',
      if (!icu.existsSync()) 'icudtl.dat — run `emb engine --arch $arch`',
      if (!engineSo.existsSync())
        'libflutter_engine.so — run `emb engine --arch $arch`',
    ];
    if (missing.isNotEmpty) {
      return BundleResult(success: false, missing: missing);
    }

    final out = Directory(outputDir);
    if (out.existsSync()) out.deleteSync(recursive: true);
    final dataDir = Directory(p.join(out.path, 'data'))
      ..createSync(recursive: true);
    final libDir = Directory(p.join(out.path, 'lib'))
      ..createSync(recursive: true);

    final outAssets = Directory(p.join(dataDir.path, 'flutter_assets'));
    _copyDir(assets, outAssets);
    icu.copySync(p.join(dataDir.path, 'icudtl.dat'));
    if (isDebug) {
      // JIT runs from kernel_blob.bin; nothing else to add.
    } else {
      // AOT runs from libapp.so — drop the now-redundant JIT kernel so it
      // isn't shipped in a profile/release bundle.
      libapp.copySync(p.join(libDir.path, 'libapp.so'));
      final kernelBlob = File(p.join(outAssets.path, 'kernel_blob.bin'));
      if (kernelBlob.existsSync()) kernelBlob.deleteSync();
    }
    engineSo.copySync(p.join(libDir.path, 'libflutter_engine.so'));

    return BundleResult(success: true, outputDir: out.path);
  }

  static void _copyDir(Directory src, Directory dst) {
    dst.createSync(recursive: true);
    for (final entity in src.listSync(recursive: true, followLinks: false)) {
      final rel = p.relative(entity.path, from: src.path);
      final target = p.join(dst.path, rel);
      if (entity is Directory) {
        Directory(target).createSync(recursive: true);
      } else if (entity is File) {
        Directory(p.dirname(target)).createSync(recursive: true);
        entity.copySync(target);
      }
    }
  }
}
