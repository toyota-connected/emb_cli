import 'dart:io';
import 'dart:isolate';

import 'package:packagekit_dart/packagekit_dart.dart';
import 'package:path/path.dart' as p;

/// Best-effort: point `packagekit_dart`'s loader at a prebuilt
/// `libpackagekit_nc.so` so the Linux backend works without the user having to
/// export `PK_NC_LIB`.
///
/// The package's loader is synchronous and cannot resolve its own location, so
/// we do it here (async) and hand the path to [setPackagekitLibraryPath] before
/// the first `PkClient` use. Two layouts are handled:
///
///  1. **Path / vendored dependency** — the `.so` sits in the package itself
///     (`<pkg>/build/` or `<pkg>/native/_build/`), found via
///     [Isolate.resolvePackageUri].
///  2. **Hosted (pub.dev) dependency** — the package dir in the pub cache is
///     read-only, so the `package:hooks` build hook compiles the `.so` into the
///     *consuming* project's `.dart_tool/hooks_runner/...` output instead. We
///     locate it there.
///
/// No-ops on non-Linux hosts, when `PK_NC_LIB` is already set, or when nothing
/// is found (e.g. a fully AOT-compiled binary) — in which case the loader's own
/// env/next-to-exe/system fallbacks still apply.
Future<void> configurePackageKitLibrary() async {
  if (!Platform.isLinux) return;
  if ((Platform.environment['PK_NC_LIB'] ?? '').isNotEmpty) return;
  try {
    // (1) The package's own prebuilt locations (path / vendored builds).
    final uri = await Isolate.resolvePackageUri(
      Uri.parse('package:packagekit_dart/packagekit_dart.dart'),
    );
    if (uri != null && uri.isScheme('file')) {
      // <pkg>/lib/packagekit_dart.dart → <pkg>
      final pkgRoot = p.dirname(p.dirname(uri.toFilePath()));
      for (final c in [
        p.join(pkgRoot, 'build', 'libpackagekit_nc.so'),
        p.join(pkgRoot, 'native', '_build', 'libpackagekit_nc.so'),
      ]) {
        if (File(c).existsSync()) {
          setPackagekitLibraryPath(c);
          return;
        }
      }
    }

    // (2) The build hook's output under the consuming project's .dart_tool.
    final hookBuilt = _findHookBuiltLibrary();
    if (hookBuilt != null) {
      setPackagekitLibraryPath(hookBuilt);
      return;
    }
  } on Object {
    // Best-effort only; fall through to the loader's other strategies.
  }
}

/// Locate the `libpackagekit_nc.so` produced by the `package:hooks` build hook,
/// which lands under `.dart_tool/hooks_runner/shared/packagekit_dart/build/`
/// `<hash>/<cmake-build-dir>/libpackagekit_nc.so` in the consuming project.
///
/// Returns the most-recently-built match, or `null` if none is found.
String? _findHookBuiltLibrary() {
  final dartTool = _locateDartTool();
  if (dartTool == null) return null;
  final buildRoot = Directory(
    p.join(dartTool, 'hooks_runner', 'shared', 'packagekit_dart', 'build'),
  );
  if (!buildRoot.existsSync()) return null;

  File? best;
  // Layout is shallow: build/<hash>/<cmake-build-dir>/libpackagekit_nc.so.
  for (final hashDir in buildRoot.listSync().whereType<Directory>()) {
    for (final cmakeDir in hashDir.listSync().whereType<Directory>()) {
      final so = File(p.join(cmakeDir.path, 'libpackagekit_nc.so'));
      if (!so.existsSync()) continue;
      if (best == null ||
          so.statSync().modified.isAfter(best.statSync().modified)) {
        best = so;
      }
    }
  }
  return best?.path;
}

/// Best-effort discovery of the consuming project's `.dart_tool` directory:
/// prefer the running package config, else walk up from the current directory.
String? _locateDartTool() {
  final pc = Platform.packageConfig;
  if (pc != null && pc.isNotEmpty) {
    final path = pc.startsWith('file:') ? Uri.parse(pc).toFilePath() : pc;
    // .../.dart_tool/package_config.json → .../.dart_tool
    final dir = p.dirname(path);
    if (p.basename(dir) == '.dart_tool' && Directory(dir).existsSync()) {
      return dir;
    }
  }
  var dir = Directory.current;
  for (var i = 0; i < 8; i++) {
    final dartTool = p.join(dir.path, '.dart_tool');
    if (Directory(dartTool).existsSync()) return dartTool;
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  return null;
}
