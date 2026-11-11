import 'dart:io';

/// A container runtime invoker (`docker` / `podman`), injectable for tests.
///
/// Returns a [ProcessResult] with the container's exit code, stdout, and
/// stderr. The default production runner uses [Process.start] with inherited
/// stdio (stdout/stderr are empty strings, exit code is real). Tests inject a
/// runner that returns buffered output.
typedef ContainerRunner =
    Future<ProcessResult> Function(
      String executable,
      List<String> args, {
      Map<String, String>? environment,
    });

/// The default production runner: inherits the parent's stdio so container
/// output (image pulls, build logs, errors) streams in real-time.
ContainerRunner _defaultRunner(String tool) =>
    (executable, args, {environment}) async {
      final process = await Process.start(
        executable,
        args,
        mode: ProcessStartMode.inheritStdio,
      );
      return ProcessResult(process.pid, await process.exitCode, '', '');
    };

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
    : _run = run ?? _defaultRunner(tool),
      _tool = tool;

  final ContainerRunner _run;
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
  /// The injected [ContainerRunner] (or the default inherited-stdio runner)
  /// handles process spawning. Output from the [ProcessResult] is routed
  /// through [onOutput]/[onError] when present and non-empty (the default
  /// production runner returns empty strings since stdio is inherited).
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

    final ProcessResult result;
    try {
      result = await _run(_tool, args);
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
