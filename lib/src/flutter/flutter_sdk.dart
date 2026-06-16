import 'dart:io';

import 'package:emb_cli/src/host/host_info.dart';
import 'package:emb_cli/src/repo/git_repo.dart';
import 'package:emb_cli/src/workspace/workspace.dart';
import 'package:path/path.dart' as p;

/// Outcome of a Flutter SDK install.
class FlutterInstallResult {
  const FlutterInstallResult({
    required this.success,
    required this.path,
    this.engineCommit,
    this.message,
  });

  final bool success;

  /// The Flutter SDK directory (`<workspace>/flutter`).
  final String path;

  /// The engine commit read from the checked-out SDK, when available.
  final String? engineCommit;

  final String? message;
}

/// Clones/checks-out the Flutter SDK into `<workspace>/flutter` and optionally
/// configures it.
///
/// Ports `get_flutter_sdk` (clone/fetch + checkout the requested version) and
/// `configure_flutter_sdk` (desktop + custom-devices config). Reuses [GitRepo]
/// for the git work so the clone/update semantics match `emb sync`.
class FlutterSdk {
  const FlutterSdk(this.workspace, {this.host});

  final Workspace workspace;
  final HostInfo? host;

  /// Upstream Flutter SDK repository.
  static const repoUrl = 'https://github.com/flutter/flutter.git';

  /// The `flutter` executable inside the SDK.
  String get flutterBin {
    final exe = Platform.isWindows ? 'flutter.bat' : 'flutter';
    return p.join(workspace.flutterDir.path, 'bin', exe);
  }

  /// Clone (or fetch + reset) the SDK and check out [version].
  Future<FlutterInstallResult> install(
    String version, {
    GitRunner runner = defaultGitRunner,
  }) async {
    final repo = GitRepo(uri: repoUrl, branch: version, destName: 'flutter');
    final result = await repo.sync(workspace.root, runner: runner);
    if (!result.success) {
      return FlutterInstallResult(
        success: false,
        path: workspace.flutterDir.path,
        message: result.message,
      );
    }
    return FlutterInstallResult(
      success: true,
      path: workspace.flutterDir.path,
      engineCommit: workspace.engineCommit(),
    );
  }

  /// Run `flutter config` for the host desktop + custom devices, then
  /// `flutter doctor -v`. Mirrors `configure_flutter_sdk`. Requires the SDK to
  /// be installed (downloads the Dart SDK on first run).
  Future<bool> configure() async {
    final h = host ?? HostInfo.detect();
    final args = <String>[
      'config',
      '--no-analytics',
      '--no-enable-web',
      '--no-enable-android',
      '--no-enable-ios',
      '--no-enable-fuchsia',
      '--enable-custom-devices',
      ...switch (h.os) {
        HostOs.linux => [
            '--enable-linux-desktop',
            '--no-enable-macos-desktop',
            '--no-enable-windows-desktop',
          ],
        HostOs.macos => [
            '--enable-macos-desktop',
            '--no-enable-linux-desktop',
            '--no-enable-windows-desktop',
          ],
        HostOs.windows => [
            '--enable-windows-desktop',
            '--no-enable-linux-desktop',
            '--no-enable-macos-desktop',
          ],
      },
    ];
    final config = await Process.run(flutterBin, args);
    if (config.exitCode != 0) return false;
    final doctor = await Process.run(flutterBin, ['doctor', '-v']);
    return doctor.exitCode == 0;
  }
}
