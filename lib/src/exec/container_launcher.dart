import 'dart:io';

/// A container runtime invoker (`docker` / `podman`), injectable for tests.
///
/// Returns a [ProcessResult] with the container's exit code, stdout, and
/// stderr. The default production runner inherits the parent's stdio so the
/// child writes directly to the terminal (stdout/stderr in the result are
/// empty). Tests inject a runner that returns buffered output for assertion.
typedef ContainerRunner =
    Future<ProcessResult> Function(String executable, List<String> args);

/// The default production runner: inherits the parent's stdio so the runtime
/// client (`docker` / `podman`) reads and writes the terminal fds directly,
/// with no drain timing to get wrong.
///
/// That gets the terminal as far as the client. Whether the container sees
/// one is up to the `-i` / `-t` flags [ContainerLauncher.argv] emits.
Future<ProcessResult> _defaultRunner(
  String executable,
  List<String> args,
) async {
  final process = await Process.start(
    executable,
    args,
    mode: ProcessStartMode.inheritStdio,
  );
  final code = await process.exitCode;
  return ProcessResult(process.pid, code, '', '');
}

/// Whether stdin is a real terminal.
///
/// `stdin.hasTerminal` is not that test: it is true for any character device,
/// `/dev/null` included, so `emb … </dev/null` would be handed `-i -t` and
/// then either hang (podman) or be refused (docker). Reading the echo mode is
/// a `tcgetattr`, which only a terminal answers.
bool _stdinIsTerminal() {
  if (!stdin.hasTerminal) return false;
  try {
    stdin.echoMode;
    return true;
  } on StdinException {
    return false;
  }
}

/// Thrown when the container tool binary (docker / podman) is not found on
/// `PATH`. Callers can distinguish this from a container that ran but exited
/// with 127 (missing command *inside* the image).
class ContainerToolNotFound implements Exception {
  ContainerToolNotFound(this.tool, this.message);

  final String tool;
  final String message;

  @override
  String toString() => '$tool: $message';
}

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
/// The default [ContainerRunner] inherits the parent's stdio. The container
/// gets an open stdin (`-i`) when emb's own stdin is a terminal, and a TTY
/// (`-t`) when stdin, stdout and stderr all are, so the inner emb, flutter,
/// ninja and git color and prompt as they would natively, and a piped,
/// redirected or CI run stays plain.
class ContainerLauncher {
  /// [interactive] and [tty] override the terminal detection; null (the
  /// default) asks the process's own stdio at [run] time.
  ContainerLauncher({
    ContainerRunner? run,
    String tool = 'docker',
    bool? interactive,
    bool? tty,
  }) : _run = run ?? _defaultRunner,
       _tool = tool,
       _interactive = interactive,
       _tty = tty;

  final ContainerRunner _run;
  final String _tool;
  final bool? _interactive;
  final bool? _tty;

  /// The container runtime argv (everything after the executable):
  /// `run --rm [-i] [-t] [-v mount…] [-w workdir] -e EMB_IN_CONTAINER=1
  /// <image> emb <embArgs> --exec-native`.
  ///
  /// [interactive] keeps the container's stdin open (`-i`); without it a read
  /// inside the container gets EOF. [tty] allocates a pseudo-terminal (`-t`);
  /// without it the container's stdout is a pipe whatever the host's is. Both
  /// default off, which is what a non-terminal caller needs: `-t` folds stderr
  /// into stdout, `-t` without `-i` leaves a read inside the container
  /// blocked forever, and `-i -t` with no terminal on stdin makes docker
  /// refuse to start ("the input device is not a TTY").
  static List<String> argv({
    required String image,
    required List<String> embArgs,
    List<Mount> mounts = const [],
    String? workdir,
    Map<String, String> env = const {},
    bool interactive = false,
    bool tty = false,
  }) {
    return [
      'run',
      '--rm',
      if (interactive) '-i',
      if (tty) '-t',
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
  /// The default production runner inherits stdio, so container output goes
  /// straight to the terminal and the [ProcessResult] strings are empty. Test
  /// runners return buffered output there.
  ///
  /// Throws [ContainerToolNotFound] when the container tool binary is absent,
  /// so callers can distinguish "docker not installed" from "command inside the
  /// container exited 127".
  Future<int> run({
    required String image,
    required List<String> embArgs,
    List<Mount> mounts = const [],
    String? workdir,
    Map<String, String> env = const {},
  }) async {
    // `-t` only when all three are terminals:
    //  * stdin, because a TTY with no `-i` gives the container a stdin that is
    //    open and never written to. A read inside blocks forever, where
    //    without `-t` it got EOF.
    //  * stdout and stderr, because `-t` merges them, and `emb … 2>err.log`
    //    on a terminal would leave the log empty.
    final interactive = _interactive ?? _stdinIsTerminal();
    final args = argv(
      image: image,
      embArgs: embArgs,
      mounts: mounts,
      workdir: workdir,
      env: env,
      interactive: interactive,
      tty: _tty ?? (interactive && stdout.hasTerminal && stderr.hasTerminal),
    );

    final ProcessResult result;
    try {
      result = await _run(_tool, args);
    } on ProcessException catch (e) {
      throw ContainerToolNotFound(_tool, e.message);
    }
    return result.exitCode;
  }
}
