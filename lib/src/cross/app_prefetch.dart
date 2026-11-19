import 'dart:io';

import 'package:emb_cli/src/cache/cache_dir.dart';
import 'package:emb_cli/src/cross/process_runner.dart';
import 'package:emb_cli/src/engine/engine_artifacts.dart';
import 'package:emb_cli/src/flutter/flutter_sdk.dart';
import 'package:emb_cli/src/host/host_info.dart';
import 'package:emb_cli/src/host/preflight.dart';
import 'package:emb_cli/src/step_reporter.dart';
import 'package:emb_cli/src/workspace/workspace.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:path/path.dart' as p;

// What an offline build of an app needs beyond the toolchain and sysroot.
// `emb fetch` and `emb cross --fetch-only` share these, so the two fetch the
// same closure.

/// Put the engine SDK for each of [modes] in the shared store and stage it in
/// [workspace], as the build would on its first run. Returns an exit code,
/// after reporting a failure. Closes [engine].
///
/// The engine is named by the commit of the workspace's Flutter SDK. With no
/// SDK there is no commit, and the build will not get as far as the engine
/// either, so that is a warning here.
Future<int> fetchAppEngines(
  EngineArtifacts engine,
  Workspace workspace, {
  required String arch,
  required List<String> modes,
  required Logger logger,
}) async {
  try {
    final commit = workspace.engineCommit();
    if (commit == null) {
      logger.warn(
        'No Flutter SDK in ${workspace.root.path}: the engine is not '
        'fetched, and an offline build needs it. Pin flutter_version: or run '
        '"emb flutter", then fetch again.',
      );
      return ExitCode.success.code;
    }
    final token = EngineArtifacts.engineArch(arch);
    for (final mode in modes) {
      final progress = StepReporter(
        logger,
      ).start('Fetching engine ($mode/$token)');
      final r = await engine.fetch(runtime: mode, arch: token, commit: commit);
      if (!r.ok) {
        progress.fail(r.message ?? 'engine ($mode/$token) fetch failed');
        return ExitCode.software.code;
      }
      progress.complete('Engine ($mode/$token) ready');
    }
    return ExitCode.success.code;
  } finally {
    engine.close();
  }
}

/// `flutter pub get` in [appPath], into the store's `PUB_CACHE`. Returns an
/// exit code, after reporting a failure.
///
/// [declared] is an app the manifest named rather than one passed with
/// `--app`. Nobody asked for its packages on this run, so what `--app`
/// treats as an error (no `flutter`, no `pubspec.lock`) is a warning there:
/// a fetch that worked before the app was cloned still does.
Future<int> prefetchAppPub(
  String appPath,
  Workspace workspace, {
  required HostInfo host,
  required Logger logger,
  required ProcessRunner run,
  required Preflight preflight,
  required bool declared,
}) async {
  final appDir = Directory(appPath);
  if (!File(p.join(appDir.path, 'pubspec.yaml')).existsSync()) {
    logger.err('no pubspec.yaml in $appPath (is it a Flutter app?)');
    return ExitCode.usage.code;
  }
  // The workspace SDK is the one the build runs, so it resolves the packages
  // when there is one.
  final sdk = FlutterSdk(workspace, host: host).flutterBin;
  final String flutter;
  if (File(sdk).existsSync()) {
    flutter = sdk;
  } else if ((await preflight.missingTools(['flutter'])).isEmpty) {
    flutter = 'flutter';
  } else if (declared) {
    logger.warn(
      'No Flutter SDK in ${workspace.root.path} or on PATH: the pub '
      'packages of ${appDir.path} are not fetched, and an offline build '
      'needs them. Run "emb flutter", then fetch again.',
    );
    return ExitCode.success.code;
  } else {
    logger.err('flutter not found on PATH — cannot prefetch pub packages.');
    await preflight.logInstallHint(host, ['flutter']);
    return ExitCode.unavailable.code;
  }
  // `--enforce-lockfile` has nothing to enforce without a lockfile, and
  // fails.
  final locked =
      !declared || File(p.join(appDir.path, 'pubspec.lock')).existsSync();
  if (!locked) {
    logger.warn(
      '${appDir.path} has no pubspec.lock: its packages are resolved now '
      'and not pinned.',
    );
  }
  // Into the store-rooted PUB_CACHE, so the packages are part of the same
  // closure the escrow archives and an offline build reads from.
  final pubCache = storePubCacheDir(ensureCacheDir())
    ..createSync(recursive: true);
  final progress = StepReporter(
    logger,
  ).start('Prefetching pub packages (${p.basename(appDir.path)})');
  final r = await run(
    flutter,
    ['pub', 'get', if (locked) '--enforce-lockfile'],
    workingDirectory: appDir.path,
    environment: {'PUB_CACHE': pubCache.path},
    output: ProcessOutputMode.stream,
    label: 'pub',
  );
  if (r.exitCode != 0) {
    progress.fail('flutter pub get failed: ${r.stderr}');
    return ExitCode.software.code;
  }
  progress.complete('Prefetched pub packages');
  return ExitCode.success.code;
}
