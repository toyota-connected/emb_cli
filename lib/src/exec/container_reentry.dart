import 'dart:io';

import 'package:emb_cli/src/exec/container_launcher.dart';
import 'package:emb_cli/src/exec/exec_env.dart';
import 'package:emb_cli/src/host/host_info.dart';

/// Routes a Linux-x86_64 emb operation into a glibc Linux container when the
/// host can't run it natively (non-Linux / non-x86_64), re-entering emb with
/// `--exec-native`. A command calls [maybeRun] near the top of `run()`: a
/// non-null result is the container's exit code (return it), null means proceed
/// natively.
class ContainerReentry {
  ContainerReentry({
    required this.host,
    ContainerLauncher? launcher,
    String? image,
    bool? inContainer,
    String? containerTool,
  }) : _launcher = launcher,
       _image = image ?? _defaultImage(),
       inContainer = inContainer ?? _detectInContainer(),
       _tool = containerTool ?? _defaultTool();

  final HostInfo host;
  final ContainerLauncher? _launcher;
  final String _image;
  final String _tool;

  /// Already inside the container (the recursion guard).
  final bool inContainer;

  static String _defaultImage() =>
      Platform.environment['EMB_RUNTIME_IMAGE'] ??
      'ghcr.io/meta-flutter/emb-engine-runtime:latest';

  static bool _detectInContainer() =>
      Platform.environment.containsKey('EMB_IN_CONTAINER');

  static String _defaultTool() =>
      Platform.environment['EMB_CONTAINER_TOOL'] ?? 'docker';

  /// Run [embArgs] in the container when routing is needed; returns the inner
  /// exit code, or null to proceed natively. [forceNative] (`--exec-native`)
  /// and being [inContainer] both short-circuit to native.
  ///
  /// [onOutput]/[onError] surface the container's stdout/stderr (used only in
  /// the buffered test path; the production path inherits stdio directly).
  /// [onRouting] is called with a human-readable reason before the container
  /// starts, so the user sees feedback immediately.
  Future<int?> maybeRun({
    required List<String> embArgs,
    required List<Mount> mounts,
    String? workdir,
    bool forceNative = false,
    void Function(String line)? onOutput,
    void Function(String line)? onError,
    void Function(String message)? onRouting,
  }) async {
    final env = resolveExecEnv(
      host,
      image: _image,
      inContainer: inContainer,
      forceNative: forceNative,
    );
    if (env is! ContainerExec) return null;
    onRouting?.call(
      'Routing through container (${env.reason}): ${env.image}',
    );
    final launcher = _launcher ?? ContainerLauncher(tool: _tool);
    return launcher.run(
      image: env.image,
      embArgs: embArgs,
      mounts: mounts,
      workdir: workdir,
      onOutput: onOutput,
      onError: onError,
    );
  }

  /// Bind-mounts for the existing directories among [dirs] (deduplicated).
  static List<Mount> mountsFor(Iterable<String?> dirs) {
    final seen = <String>{};
    final mounts = <Mount>[];
    for (final d in dirs) {
      if (d == null) continue;
      final path = Directory(d).absolute.path;
      if (!seen.add(path)) continue;
      if (Directory(path).existsSync()) mounts.add(Mount(path));
    }
    return mounts;
  }
}
