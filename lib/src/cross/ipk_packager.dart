import 'dart:io';

import 'package:emb_cli/src/cross/control_archive_packager.dart';
import 'package:emb_cli/src/cross/process_runner.dart';
import 'package:path/path.dart' as p;

/// Control metadata for a generated `.ipk`.
///
/// The same field set as a `.deb` control file, but `Depends` is explicit only:
/// opkg/Yocto sysroots carry no dpkg database to derive ownership from, so the
/// auto-`Depends` step (deb's `DT_NEEDED` → package lookup) does not apply.
class IpkMetadata {
  const IpkMetadata({
    required this.name,
    required this.version,
    required this.architecture,
    required this.maintainer,
    required this.description,
    this.section = 'misc',
    this.priority = 'optional',
    this.depends = const [],
  });

  final String name;
  final String version;

  /// opkg architecture (e.g. `aarch64`, `cortexa53`), not the GNU triple.
  final String architecture;
  final String maintainer;
  final String description;
  final String section;
  final String priority;

  /// Explicit `Depends` entries (opkg has no auto-derivation here).
  final List<String> depends;
}

/// Thrown when packaging an `.ipk` fails.
class IpkPackageException implements Exception {
  IpkPackageException(this.message);
  final String message;
  @override
  String toString() => 'IpkPackageException: $message';
}

/// Builds an opkg `.ipk` from a cross-built binary, via `opkg-build`.
///
/// Structurally a sibling of `DebPackager`: it reuses the shared staging +
/// control-file machinery (binary at install path, `files:`, `CONTROL/`
/// directory, maintainer scripts), differing only in the control dir name and
/// the build tool. Targets opkg/OpenEmbedded systems; needs `opkg-build`
/// (from `opkg-utils`) on the build host.
class IpkPackager extends ControlArchivePackager {
  IpkPackager({ProcessRunner runProcess = defaultProcessRunner})
    : super(runProcess);

  @override
  String get controlDir => 'CONTROL';

  @override
  Never fail(String message) => throw IpkPackageException(message);

  /// Package [binary] to `<outDir>/<name>_<version>_<arch>.ipk`, installing it
  /// at the absolute [installPath] on the target. [extraFiles] maps host source
  /// paths to absolute target paths; [maintainerScripts] maps a script name
  /// (`preinst`/`postinst`/`prerm`/`postrm`) to the host file staged into
  /// `CONTROL/` (0755).
  Future<File> build({
    required File binary,
    required String installPath,
    required IpkMetadata meta,
    required Directory outDir,
    Map<String, String> extraFiles = const {},
    Map<String, String> fileModes = const {},
    Map<String, String> maintainerScripts = const {},
  }) async {
    if (await _which('opkg-build') == null) {
      fail(
        'opkg-build not found on PATH — install opkg-utils (which provides '
        'opkg-build) to package .ipk files.',
      );
    }

    final deps = [...meta.depends]..sort();
    final stageRoot = await stage(
      binary: binary,
      installPath: installPath,
      packageName: meta.name,
      control: controlBody(
        name: meta.name,
        version: meta.version,
        architecture: meta.architecture,
        maintainer: meta.maintainer,
        description: meta.description,
        section: meta.section,
        priority: meta.priority,
        depends: deps,
      ),
      outDir: outDir,
      extraFiles: extraFiles,
      fileModes: fileModes,
      maintainerScripts: maintainerScripts,
    );

    // opkg-build reads the control fields and writes
    // <name>_<version>_<arch>.ipk into the destination dir. `-o root -g root`
    // forces ownership so it stays reproducible without running as root.
    final r = await run('opkg-build', [
      '-o',
      'root',
      '-g',
      'root',
      stageRoot.path,
      outDir.path,
    ], output: ProcessOutputMode.stream);
    stageRoot.deleteSync(recursive: true);
    if (r.exitCode != 0) {
      throw IpkPackageException('opkg-build failed: ${r.stderr}');
    }
    final out = File(
      p.join(
        outDir.path,
        '${meta.name}_${meta.version}_${meta.architecture}.ipk',
      ),
    );
    if (!out.existsSync()) {
      throw IpkPackageException('opkg-build did not produce ${out.path}');
    }
    return out;
  }

  /// Locate [exe] on PATH (`command -v`), or null when absent.
  Future<String?> _which(String exe) async {
    final r = await run('command', ['-v', exe], runInShell: true);
    if (r.exitCode != 0) return null;
    final out = r.stdout.trim();
    return out.isEmpty ? null : out;
  }
}
