import 'dart:io';

/// A container runtime invoker (`docker` / `podman`), injectable for tests.
///
/// The default runner inherits the parent process's stdio so container output
/// streams in real-time. Tests inject a [ContainerRunner] that returns a
/// [ProcessResult] synchronously.
typedef ContainerRunner =
    Future<ProcessResult> Function(
      String executable,
      List<String> args,
    );

/// A host bind-mount, exposed at the same path inside the container.
class Mount {
  const Mount(this.path, {this.containerPath, this.readOnly = false});

  final String path;

  /// Path inside the container. Defaults to [path] (same as host).
  final String? containerPath;
  final bool readOnly;

  String get spec {
    final dst = containerPath ?? path;
    return readOnly ? '$path:$dst:ro' : '$path:$dst';
  }
}

/// Re-enters emb inside a glibc Linux container to run a Linux-x86_64 operation
/// on a non-Linux / non-x86_64 host. The re-entry always carries `--exec-native`
/// and sets `EMB_IN_CONTAINER=1` so the inner emb runs directly (recursion
/// guard).
class ContainerLauncher {
  ContainerLauncher({ContainerRunner? run, String tool = 'docker'})
    : _run = run,
      _tool = tool;

  final ContainerRunner? _run;
  final String _tool;

  /// The container runtime argv (everything after the executable):
  /// `run --rm [-v mount…] [-w workdir] -e EMB_IN_CONTAINER=1 <image>
  /// emb <embArgs> --exec-native`.
  static List<String> argv({
    required String image,
    required List<String> embArgs,
    List<Mount> mounts = const [],
    String? workdir,
    Map<String, String> env = const {},
  }) {
    return [
      'run',
      '--rm',
      for (final m in mounts) ...['-v', m.spec],
      if (workdir != null) ...['-w', workdir],
      '-e',
      'EMB_IN_CONTAINER=1',
      for (final e in env.entries) ...['-e', '${e.key}=${e.value}'],
      image,
      'emb',
      ...embArgs,
      '--exec-native',
    ];
  }

  /// Run [embArgs] inside [image]; returns the inner emb's exit code.
  ///
  /// When no test [ContainerRunner] was injected, uses [Process.start] with
  /// inherited stdio so the user sees container output in real-time (image
  /// pulls, build logs, errors). When a runner is injected (tests), falls
  /// back to the buffered path and routes output through [onOutput]/[onError].
  ///
  /// Returns 127 (command-not-found convention) when the container tool
  /// binary is absent, instead of letting the [ProcessException] propagate
  /// unhandled.
  Future<int> run({
    required String image,
    required List<String> embArgs,
    List<Mount> mounts = const [],
    String? workdir,
    Map<String, String> env = const {},
    void Function(String line)? onOutput,
    void Function(String line)? onError,
  }) async {
    final args = argv(
      image: image,
      embArgs: embArgs,
      mounts: mounts,
      workdir: workdir,
      env: env,
    );

    // Test path: injected runner, buffered output.
    if (_run != null) {
      return _runBuffered(
        args,
        onOutput: onOutput,
        onError: onError,
      );
    }

    // Production path: inherited stdio, real-time output.
    try {
      final process = await Process.start(
        _tool,
        args,
        mode: ProcessStartMode.inheritStdio,
      );
      return await process.exitCode;
    } on ProcessException catch (e) {
      onError?.call('$_tool: ${e.message}');
      return 127;
    }
  }

  /// Buffered fallback used when a [ContainerRunner] is injected (tests).
  Future<int> _runBuffered(
    List<String> args, {
    void Function(String line)? onOutput,
    void Function(String line)? onError,
  }) async {
    final ProcessResult result;
    try {
      result = await _run!(_tool, args);
    } on ProcessException catch (e) {
      onError?.call('$_tool: ${e.message}');
      return 127;
    }
    if (onOutput != null) {
      final out = result.stdout as String;
      if (out.isNotEmpty) {
        for (final line in out.split('\n')) {
          if (line.isNotEmpty) onOutput(line);
        }
      }
    }
    if (onError != null) {
      final err = result.stderr as String;
      if (err.isNotEmpty) {
        for (final line in err.split('\n')) {
          if (line.isNotEmpty) onError(line);
        }
      }
    }
    return result.exitCode;
  }
}
