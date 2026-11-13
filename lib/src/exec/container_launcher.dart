import 'dart:async';
import 'dart:io';

/// A container runtime invoker (`docker` / `podman`), injectable for tests.
///
/// Returns a [ProcessResult] with the container's exit code, stdout, and
/// stderr. The default production runner pipes output and forwards it to the
/// terminal in real-time (stdout/stderr in the result are empty). Tests inject
/// a runner that returns buffered output for assertion.
typedef ContainerRunner =
    Future<ProcessResult> Function(String executable, List<String> args);

/// The default production runner: pipes stdout/stderr and forwards raw bytes
/// to the terminal in real-time, draining both streams before returning so no
/// output is lost.
ContainerRunner _defaultRunner(String tool) => (executable, args) async {
  final process = await Process.start(executable, args);
  final out = process.stdout.listen(stdout.add);
  final err = process.stderr.listen(stderr.add);
  final code = await process.exitCode;
  await out.asFuture<void>();
  await err.asFuture<void>();
  unawaited(out.cancel());
  unawaited(err.cancel());
  return ProcessResult(process.pid, code, '', '');
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
///
/// The default [ContainerRunner] pipes stdout/stderr and forwards raw bytes to
/// the terminal, draining both streams before returning so no output is lost.
/// Test runners return buffered output in [ProcessResult]; `run()` routes it
/// through callbacks or falls back to [stdout]/[stderr].
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
  /// The default production runner pipes stdout/stderr to the terminal in
  /// real-time and returns empty strings. Test runners return buffered output
  /// which is routed through [onOutput]/[onError]; when either callback is
  /// null the corresponding stream is forwarded to [stdout]/[stderr] so
  /// output is never silently discarded.
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
      final errSink = onError ?? (String s) => stderr.writeln(s);
      errSink('$_tool: ${e.message}');
      return 127;
    }
    _forwardLines(result.stdout as String, onOutput ?? stdout.writeln);
    _forwardLines(result.stderr as String, onError ?? stderr.writeln);
    return result.exitCode;
  }

  static void _forwardLines(String text, void Function(String) sink) {
    if (text.isEmpty) return;
    for (final line in text.split('\n')) {
      if (line.isNotEmpty) sink(line);
    }
  }
}
