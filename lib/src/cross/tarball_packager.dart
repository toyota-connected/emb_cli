import 'dart:io';

import 'package:emb_cli/src/cross/package_stager.dart';
import 'package:emb_cli/src/cross/process_runner.dart';
import 'package:path/path.dart' as p;

/// Metadata for a generated `.tar.gz`. Just enough to name the archive — a
/// tarball carries no control metadata or dependencies.
class TarballMetadata {
  const TarballMetadata({
    required this.name,
    required this.version,
    required this.architecture,
  });

  final String name;
  final String version;

  /// CPU arch token (e.g. `aarch64`), used only in the output filename.
  final String architecture;
}

/// Thrown when packaging a `.tar.gz` fails.
class TarballPackageException implements Exception {
  TarballPackageException(this.message);
  final String message;
  @override
  String toString() => 'TarballPackageException: $message';
}

/// Builds a relocatable `.tar.gz` from a cross-built binary — the universal
/// fallback for targets with no package manager (buildroot, initramfs, plain
/// `scp`). Reuses [PackageStager] to lay the binary and `files:` at their
/// on-target paths, then `tar -czf`s the tree rooted at the target's `/`, so it
/// unpacks with `tar -C / -xzf <archive>`.
///
/// Maintainer scripts do not apply — nothing runs them on extraction — so this
/// format honours `files:` but ignores `scripts:`. Needs only `tar`.
class TarballPackager extends PackageStager {
  TarballPackager({ProcessRunner runProcess = defaultProcessRunner})
    : super(runProcess);

  @override
  Never fail(String message) => throw TarballPackageException(message);

  /// Package [binary] to `<outDir>/<name>_<version>_<arch>.tar.gz`, placing it
  /// at the absolute [installPath] within the archive. [extraFiles] maps host
  /// source paths to absolute target paths.
  Future<File> build({
    required File binary,
    required String installPath,
    required TarballMetadata meta,
    required Directory outDir,
    Map<String, String> extraFiles = const {},
    Map<String, String> fileModes = const {},
  }) async {
    final root = await stagePayload(
      binary: binary,
      installPath: installPath,
      packageName: meta.name,
      outDir: outDir,
      extraFiles: extraFiles,
      fileModes: fileModes,
    );

    final out = File(
      p.join(
        outDir.path,
        '${meta.name}_${meta.version}_${meta.architecture}.tar.gz',
      ),
    );
    // `-C <root> .` packs paths relative to the target root (./usr/bin/…).
    final r = await run('tar', ['-czf', out.path, '-C', root.path, '.']);
    root.deleteSync(recursive: true);
    if (r.exitCode != 0) {
      throw TarballPackageException('tar failed: ${r.stderr}');
    }
    return out;
  }
}
