import 'dart:io';

import 'package:emb_cli/src/cross/elf_check.dart';
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
    _stageCodeAssets(outAssets, libDir);

    // Every ELF in lib/ must be built for the target. The engine and the AOT
    // image are staged from per-arch directories and so are hard to get wrong,
    // but a code asset comes from a Dart build hook, and a hook that resolved a
    // *host* compiler produces a host-arch .so that loads fine on the build
    // machine and dies at dlopen on the device — surfacing in Dart as a symbol
    // lookup failure, several steps from the cause. `emb cross` has audited
    // this since #96; `emb bundle` and `emb build` reach the same staging code
    // and did not.
    final wrongArch = <String>[
      for (final f in libDir.listSync(followLinks: false).whereType<File>())
        if (verifyElfForTriple(f, arch) case final reason?)
          '${p.basename(f.path)}: $reason',
    ]..sort();
    if (wrongArch.isNotEmpty) {
      return BundleResult(
        success: false,
        message:
            'bundle lib/ holds ${wrongArch.length} file(s) not built for '
            '$arch:\n  ${wrongArch.join("\n  ")}\n'
            'Rebuild them for $arch, or drop the dependency that produces '
            'them. A native asset from a Dart build hook needs the hook to '
            'honor the cross toolchain.',
      );
    }

    return BundleResult(success: true, outputDir: out.path);
  }

  /// Copy the app's code assets (native assets) into the bundle's `lib/`.
  ///
  /// A package with a build hook produces shared libraries that the engine
  /// resolves through `NativeAssetsManifest.json` at runtime. That manifest
  /// names each one by bare filename, so resolution goes through the dynamic
  /// loader's search path — which means the library has to sit next to
  /// `libflutter_engine.so`, not only inside `flutter_assets/native_assets/`
  /// where `flutter build bundle` leaves it. Without this the app links against
  /// nothing at runtime and the `@Native` bindings fail to resolve.
  ///
  /// The manifest stays in `flutter_assets` untouched — it is what the engine
  /// reads to know which library backs which asset id.
  static void _stageCodeAssets(Directory assets, Directory libDir) {
    final nativeAssets = Directory(p.join(assets.path, 'native_assets'));
    if (!nativeAssets.existsSync()) {
      return;
    }
    for (final entity in nativeAssets.listSync(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is! File) {
        continue;
      }
      // Flattened deliberately: the manifest resolves by bare name, so the
      // per-OS subdirectory layout underneath means nothing to the loader.
      final dest = p.join(libDir.path, p.basename(entity.path));
      if (!File(dest).existsSync()) {
        entity.copySync(dest);
      }
    }
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
