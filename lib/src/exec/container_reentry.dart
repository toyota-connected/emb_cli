import 'dart:io';

import 'package:emb_cli/src/exec/container_launcher.dart';
import 'package:emb_cli/src/exec/exec_env.dart';
import 'package:emb_cli/src/host/host_info.dart';
import 'package:emb_cli/src/verbosity.dart';

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
    final auth = containerAuthContext();
    final launcher = _launcher ?? ContainerLauncher(tool: _tool);
    return launcher.run(
      image: env.image,
      embArgs: embArgs,
      mounts: [...mounts, ...auth.mounts],
      workdir: workdir,
      env: auth.env,
      onOutput: onOutput,
      onError: onError,
    );
  }

  /// Docker Desktop's built-in SSH agent socket, available inside the Linux
  /// VM on macOS/Windows. Bind-mounting the host's `$SSH_AUTH_SOCK` directly
  /// fails because Docker Desktop can't reach host-side Unix sockets.
  static const _dockerDesktopSshSock =
      '/run/host-services/ssh-auth.sock';

  /// Credentials and verbosity to forward into any container re-entry.
  ///
  /// Extracted so both [maybeRun] and direct [ContainerLauncher.run] callers
  /// (e.g. `engine_command`) share the same forwarding logic. Reads
  /// `SSH_AUTH_SOCK`, `GH_TOKEN`/`GITHUB_TOKEN`, and [embVerbosity] from
  /// the host environment.
  ///
  /// On macOS (and Windows), the host's SSH agent socket can't be
  /// bind-mounted directly — Docker Desktop exposes it at a magic path
  /// inside the VM instead. When `SSH_AUTH_SOCK` is set on a non-Linux
  /// host, we mount that magic path and point the container's
  /// `SSH_AUTH_SOCK` at it.
  static ContainerAuthContext containerAuthContext({
    Map<String, String>? hostEnv,
    bool? isMacOrWin,
  }) {
    final env = hostEnv ?? Platform.environment;
    final sshSock = env['SSH_AUTH_SOCK'];
    final isDesktopHost =
        isMacOrWin ?? (Platform.isMacOS || Platform.isWindows);
    final ghToken = env['GH_TOKEN'] ?? env['GITHUB_TOKEN'];
    final verbosityIndex = embVerbosity.index;

    // SSH agent forwarding: on Linux, bind-mount the host socket directly.
    // On macOS/Windows, Docker Desktop provides a VM-side socket at a
    // well-known path — mount that instead.
    final sshMounts = <Mount>[];
    String? containerSshSock;
    if (sshSock != null) {
      if (isDesktopHost) {
        sshMounts.add(const Mount(_dockerDesktopSshSock));
        containerSshSock = _dockerDesktopSshSock;
      } else if (File(sshSock).existsSync()) {
        sshMounts.add(Mount(sshSock));
        containerSshSock = sshSock;
      }
    }

    // Git HTTPS auth: prefer the host's ~/.netrc (read-only mount keeps the
    // token off the docker CLI). Fall back to GIT_CONFIG env vars when no
    // .netrc exists but GH_TOKEN / GITHUB_TOKEN is set (typical in CI).
    final credMounts = <Mount>[];
    final home = env['HOME'];
    final netrc = home != null ? File('$home/.netrc') : null;
    final hasNetrc = netrc != null && netrc.existsSync();
    if (hasNetrc) {
      credMounts.add(
        Mount(netrc.path, containerPath: '/root/.netrc', readOnly: true),
      );
    }

    return ContainerAuthContext(
      mounts: [...sshMounts, ...credMounts],
      env: {
        if (verbosityIndex > Verbosity.normal.index)
          'EMB_VERBOSITY': '$verbosityIndex',
        if (containerSshSock != null) 'SSH_AUTH_SOCK': containerSshSock,
        // Fall back to env-var git config only when there's no .netrc to
        // mount. The token is visible in `ps aux` via docker's -e flag,
        // which is acceptable on isolated CI runners.
        if (!hasNetrc && ghToken != null) ...{
          'GIT_CONFIG_COUNT': '1',
          'GIT_CONFIG_KEY_0':
              'url.https://x-access-token:$ghToken@github.com/.insteadOf',
          'GIT_CONFIG_VALUE_0': 'https://github.com/',
        },
      },
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

/// Mounts and environment variables for forwarding host credentials into a
/// container (SSH agent socket, GitHub token, verbosity).
class ContainerAuthContext {
  const ContainerAuthContext({
    required this.mounts,
    required this.env,
  });

  /// Bind-mounts for credential sockets (e.g. SSH agent).
  final List<Mount> mounts;

  /// Environment variables to pass with `-e` (auth + verbosity).
  final Map<String, String> env;
}
