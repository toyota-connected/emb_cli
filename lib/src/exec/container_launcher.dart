import 'dart:io';

/// A container runtime invoker (`docker` / `podman`), injectable for tests.
typedef ContainerRunner =
    Future<ProcessResult> Function(
      String executable,
      List<String> args, {
      Map<String, String>? environment,
    });

/// A host bind-mount, exposed at the same path inside the container.
class Mount {
  const Mount(this.path, {this.readOnly = false});

  final String path;
  final bool readOnly;

  String get spec => readOnly ? '$path:$path:ro' : '$path:$path';
}

/// Re-enters emb inside a glibc Linux container to run a Linux-x86_64 operation
/// on a non-Linux / non-x86_64 host. The re-entry always carries `--exec-native`
/// and sets `EMB_IN_CONTAINER=1` so the inner emb runs directly (recursion
/// guard).
class ContainerLauncher {
  ContainerLauncher({ContainerRunner? run, String tool = 'docker'})
    : _run = run ?? _defaultRunner,
      _tool = tool;

  final ContainerRunner _run;
  final String _tool;

  static Future<ProcessResult> _defaultRunner(
    String executable,
    List<String> args, {
    Map<String, String>? environment,
  }) => Process.run(executable, args, environment: environment);

  /// The container runtime argv (everything after the executable):
  /// `run --rm [-v mount…] [-w workdir] -e EMB_IN_CONTAINER=1 <image>
  /// emb <embArgs> --exec-native`.
  static List<String> argv({
    required String image,
    required List<String> embArgs,
    List<Mount> mounts = const [],
    String? workdir,
  }) {
    return [
      'run',
      '--rm',
      for (final m in mounts) ...['-v', m.spec],
      if (workdir != null) ...['-w', workdir],
      '-e',
      'EMB_IN_CONTAINER=1',
      image,
      'emb',
      ...embArgs,
      '--exec-native',
    ];
  }

  /// Run [embArgs] inside [image]; returns the inner emb's exit code.
  Future<int> run({
    required String image,
    required List<String> embArgs,
    List<Mount> mounts = const [],
    String? workdir,
  }) async {
    final result = await _run(
      _tool,
      argv(image: image, embArgs: embArgs, mounts: mounts, workdir: workdir),
    );
    return result.exitCode;
  }
}
