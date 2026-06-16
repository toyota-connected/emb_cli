import 'dart:io';
import 'dart:isolate';

import 'package:packagekit_dart/packagekit_dart.dart';
import 'package:path/path.dart' as p;

/// Best-effort: point `packagekit_dart`'s loader at the package's own prebuilt
/// `libpackagekit_nc.so` so the Linux backend works without the user having to
/// export `PK_NC_LIB`.
///
/// The package's loader is synchronous and cannot resolve its own location, so
/// we do it here (async) via [Isolate.resolvePackageUri] and hand the path to
/// [setPackagekitLibraryPath] before the first `PkClient` use. No-ops on
/// non-Linux hosts, when `PK_NC_LIB` is already set, or when the package can't
/// be resolved (e.g. fully AOT-compiled) — in which case the loader's own
/// env/next-to-exe/system fallbacks still apply.
Future<void> configurePackageKitLibrary() async {
  if (!Platform.isLinux) return;
  if ((Platform.environment['PK_NC_LIB'] ?? '').isNotEmpty) return;
  try {
    final uri = await Isolate.resolvePackageUri(
      Uri.parse('package:packagekit_dart/packagekit_dart.dart'),
    );
    if (uri == null || !uri.isScheme('file')) return;
    // <pkg>/lib/packagekit_dart.dart → <pkg>
    final pkgRoot = p.dirname(p.dirname(uri.toFilePath()));
    final candidates = [
      p.join(pkgRoot, 'build', 'libpackagekit_nc.so'),
      p.join(pkgRoot, 'native', '_build', 'libpackagekit_nc.so'),
    ];
    for (final c in candidates) {
      if (File(c).existsSync()) {
        setPackagekitLibraryPath(c);
        return;
      }
    }
  } on Object {
    // Best-effort only; fall through to the loader's other strategies.
  }
}
