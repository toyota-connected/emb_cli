import 'dart:io';

import 'package:emb_cli/src/cross/process_runner.dart';
import 'package:emb_cli/src/env/env_script.dart';
import 'package:emb_cli/src/flutter/flutter_sdk.dart';
import 'package:emb_cli/src/host/host_info.dart';
import 'package:emb_cli/src/repo/git_repo.dart';
import 'package:emb_cli/src/step_reporter.dart';
import 'package:emb_cli/src/workspace/workspace.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:path/path.dart' as p;

/// Provision the Flutter SDK a manifest pins as [version], when [workspace]
/// has none, and precache what a build reads from it. False after reporting
/// why it could not. An SDK already there is left alone, whatever its
/// version; `emb flutter` changes it. No [version] is nothing to do.
///
/// `emb cross --build` and `emb fetch` share this: with [offline] nothing is
/// downloaded, so whatever is missing has to have been fetched beforehand.
Future<bool> ensureFlutterSdk(
  String? version,
  Workspace workspace, {
  required HostInfo host,
  required Logger logger,
  required ProcessRunner run,
  required bool offline,
  GitRunner gitRunner = defaultGitRunner,
}) async {
  if (version == null || version.isEmpty) return true;
  final sdk = FlutterSdk(workspace, host: host);
  final steps = StepReporter(logger);

  if (!File(sdk.flutterBin).existsSync()) {
    if (offline) {
      logger.err(
        '  --offline cannot install Flutter SDK $version into '
        '${workspace.flutterDir.path} — run "emb fetch" or "emb flutter" '
        'once online.',
      );
      return false;
    }
    final progress = steps.start('Installing Flutter SDK $version');
    final result = await sdk.install(version, runner: gitRunner);
    if (!result.success) {
      progress.fail('Flutter SDK $version: ${result.message ?? "failed"}');
      return false;
    }
    progress.complete('Flutter SDK $version → ${workspace.flutterDir.path}');
    File(p.join(workspace.root.path, 'setup_env.sh')).writeAsStringSync(
      generateSetupEnv(
        workspace: workspace,
        host: host,
        engineVersion: result.engineCommit,
      ),
    );
  }

  // emb picks its frontend_server by probing bin/cache before it invokes
  // flutter, and a fresh clone has none — so a cold workspace takes the wrong
  // branch and the kernel snapshot fails. No-op once populated.
  final snapshot = File(
    p.join(
      workspace.flutterDir.path,
      'bin/cache/dart-sdk/bin/snapshots/frontend_server_aot.dart.snapshot',
    ),
  );
  if (!snapshot.existsSync()) {
    if (offline) {
      logger.err(
        '  --offline cannot precache the Flutter SDK in '
        '${workspace.flutterDir.path} — run "emb fetch" once online.',
      );
      return false;
    }
    final progress = steps.start('Precaching Flutter artifacts');
    final r = await run(sdk.flutterBin, [
      'precache',
      '--linux',
      '--no-universal',
    ], output: ProcessOutputMode.stream);
    if (r.exitCode != 0) {
      progress.fail('flutter precache failed');
      return false;
    }
    progress.complete('Flutter artifacts precached');
  }
  return true;
}
