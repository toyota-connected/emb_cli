import 'dart:io';

import 'package:emb_cli/src/aot/aot_builder.dart';
import 'package:emb_cli/src/bundle/bundle_builder.dart';
import 'package:emb_cli/src/engine/engine_artifacts.dart';
import 'package:emb_cli/src/workspace/workspace.dart';
import 'package:path/path.dart' as p;

/// Build (optionally) + ensure engine + assemble one (arch, mode) bundle.
///
/// Shared by `emb bundle` and `emb build` so both behave identically:
///  * when [build], compile the app — `flutter build bundle --debug` (JIT) for
///    debug, or AOT (`gen_snapshot` → `libapp.so`) for profile/release;
///  * **implicitly fetch the engine SDK** for (mode, arch) when it isn't
///    already staged (keyed by the SDK's engine commit), so you don't have to
///    run `emb engine` first;
///  * assemble the ivi-homescreen bundle into [outputDir].
Future<BundleResult> buildAndAssemble({
  required Workspace workspace,
  required AotBuilder aot,
  required BundleBuilder bundle,
  required String appPath,
  required String arch,
  required String mode,
  required String outputDir,
  required bool build,
  EngineArtifacts? engine,
  void Function(String step)? onStep,
}) async {
  // 1. Ensure the engine SDK for (mode, arch) is staged FIRST — it provides
  //    both the gen_snapshot the AOT step needs and the icudtl/engine the
  //    assembly needs. Fetch when the staged bundle is missing OR was staged
  //    from a different engine commit (workspace Flutter updated since last
  //    run).
  if (engine != null) {
    final commit = workspace.engineCommit();
    if (commit != null) {
      final engineDir = bundle.engineBundleDir(mode, arch).path;
      final stamp = File(p.join(engineDir, '.engine_commit'));
      final stampedCommit = stamp.existsSync()
          ? stamp.readAsStringSync().trim()
          : null;
      if (stampedCommit != commit) {
        final token = EngineArtifacts.engineArch(arch);
        onStep?.call('fetching engine ($mode/$token)');
        final result = await engine.fetch(
          runtime: mode,
          arch: token,
          commit: commit,
          clean: true,
        );
        if (result.ok) {
          stamp.writeAsStringSync(commit);
        }
      }
    }
  }

  // 2. Compile the app.
  if (build) {
    if (mode == 'debug') {
      onStep?.call('flutter build bundle --debug');
      if (!await aot.buildAssets(appPath: appPath, mode: mode, arch: arch)) {
        return const BundleResult(
          success: false,
          message: 'flutter build bundle --debug failed',
        );
      }
    } else {
      onStep?.call('AOT ($mode)');
      final r = await aot.build(appPath: appPath, modes: [mode], arch: arch);
      if (!r.success) {
        final failed = r.modes.firstWhere((m) => !m.success);
        return BundleResult(success: false, message: failed.message);
      }
    }
  }

  // 3. Assemble.
  onStep?.call('assembling bundle');
  return bundle.assemble(
    appPath: appPath,
    mode: mode,
    arch: arch,
    outputDir: outputDir,
  );
}

/// The default bundle output directory: `<workspace>/bundle/<app>-<mode>-<token>`.
String defaultBundleOutput(
  Workspace workspace,
  String appPath,
  String mode,
  String arch,
) {
  final name = p.basename(p.absolute(appPath));
  final token = EngineArtifacts.engineArch(arch);
  return p.join(workspace.root.path, 'bundle', '$name-$mode-$token');
}
