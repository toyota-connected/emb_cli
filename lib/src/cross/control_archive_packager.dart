import 'dart:io';

import 'package:emb_cli/src/cross/package_stager.dart';
import 'package:path/path.dart' as p;

/// Shared machinery for the "control-archive" package formats — Debian `.deb`
/// and opkg `.ipk` — which are structurally the same: the staged payload (from
/// [PackageStager]) plus a control directory (`DEBIAN/` for deb, `CONTROL/` for
/// ipk) carrying a `control` file and optional maintainer scripts, then handed
/// to a format-specific build tool.
///
/// Subclasses supply the control dir name, their typed exception, and the
/// archive-build step; the control-file body and maintainer-script staging
/// live here, payload staging in [PackageStager].
abstract class ControlArchivePackager extends PackageStager {
  ControlArchivePackager(super.run);

  /// The control directory name inside the staging root (`DEBIAN` / `CONTROL`).
  String get controlDir;

  /// The maintainer-script names both formats honour, in install→remove order.
  static const maintainerScriptNames = [
    'preinst',
    'postinst',
    'prerm',
    'postrm',
  ];

  /// The control-file body. deb and ipk share the same field set; `Depends` is
  /// emitted only when non-empty.
  String controlBody({
    required String name,
    required String version,
    required String architecture,
    required String maintainer,
    required String description,
    String section = 'misc',
    String priority = 'optional',
    List<String> depends = const [],
  }) {
    final b = StringBuffer()
      ..writeln('Package: $name')
      ..writeln('Version: $version')
      ..writeln('Architecture: $architecture')
      ..writeln('Maintainer: $maintainer')
      ..writeln('Section: $section')
      ..writeln('Priority: $priority');
    if (depends.isNotEmpty) b.writeln('Depends: ${depends.join(', ')}');
    // Both formats require a synopsis line; indent any continuation.
    b.writeln('Description: $description');
    return b.toString();
  }

  /// Stage the payload plus [maintainerScripts] (script name → host file),
  /// writing [control] into the control dir (0755 on each script). Returns the
  /// staging root for the format's build step to consume.
  Future<Directory> stage({
    required File binary,
    required String installPath,
    required String packageName,
    required String control,
    required Directory outDir,
    Map<String, String> extraFiles = const {},
    Map<String, String> maintainerScripts = const {},
  }) async {
    for (final name in maintainerScripts.keys) {
      if (!maintainerScriptNames.contains(name)) {
        fail(
          'unknown maintainer script "$name" '
          '(expected one of: ${maintainerScriptNames.join(", ")})',
        );
      }
    }

    final root = await stagePayload(
      binary: binary,
      installPath: installPath,
      packageName: packageName,
      outDir: outDir,
      extraFiles: extraFiles,
    );

    File(p.join(root.path, controlDir, 'control'))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(control);

    // Stage maintainer scripts into the control dir as executables; the package
    // manager runs them at the matching phase (preinst/postinst on install,
    // prerm/postrm on remove).
    for (final entry in maintainerScripts.entries) {
      final src = File(entry.value);
      if (!src.existsSync()) {
        fail('maintainer script not found: ${entry.value}');
      }
      final to = File(p.join(root.path, controlDir, entry.key));
      src.copySync(to.path);
      await run('chmod', ['0755', to.path]);
    }
    return root;
  }
}
