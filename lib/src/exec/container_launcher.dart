import 'dart:async';
import 'dart:io';

import 'package:emb_cli/src/exec/termination_signals.dart';
import 'package:meta/meta.dart';

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
///
/// While the client runs, SIGINT and SIGTERM are passed on to it and emb
/// waits for it to exit. Left at the default, the signal kills emb at once:
/// the prompt comes back while the container is still stopping, and a signal
/// sent to emb alone (`kill`, a CI cancel) never reaches the client, so the
/// container runs on with nothing attached. The client forwards the signal
/// to the container, and emb reports the exit code that results.
///
/// A second signal kills the client and stops waiting. An image whose emb
/// predates its PID 1 signal handling ignores the forwarded signal, and
/// without this emb could not be interrupted until the build finished.
///
/// A client that itself died of a signal is reported the way a shell would,
/// as 128 + the signal number, not as Dart's negative code.
///
/// [watch] is the signal source, replaceable for tests. Not on Windows: there
/// Ctrl-C goes to every process on the console, and [Process.kill] can only
/// terminate the client outright.
@visibleForTesting
ContainerRunner containerRunner({SignalWatcher? watch}) =>
    (executable, args) async {
      final process = await Process.start(
        executable,
        args,
        mode: ProcessStartMode.inheritStdio,
      );
      var forwarded = false;
      void onSignal(ProcessSignal signal) {
        process.kill(forwarded ? ProcessSignal.sigkill : signal);
        forwarded = true;
      }

      final subs = <StreamSubscription<ProcessSignal>>[
        if (!Platform.isWindows)
          for (final s in terminationSignals)
            (watch ?? (s) => s.watch())(s).listen(onSignal),
      ];
      try {
        final code = await process.exitCode;
        return ProcessResult(process.pid, code < 0 ? 128 - code : code, '', '');
      } finally {
        for (final sub in subs) {
          await sub.cancel();
        }
      }
    };

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

/// Whether a process with this `/proc/<pid>/stat` line is in its terminal's
/// foreground process group: field 5 (`pgrp`) equals field 8 (`tpgid`).
///
/// The command name (field 2) may hold spaces and parentheses, so the fields
/// are counted from the last `)`. False for anything unparseable.
@visibleForTesting
bool foregroundFromStat(String stat) {
  final close = stat.lastIndexOf(')');
  if (close < 0) return false;
  // After the name: state ppid pgrp session tty_nr tpgid …
  final f = stat.substring(close + 1).trim().split(RegExp(r'\s+'));
  if (f.length < 6) return false;
  final pgrp = int.tryParse(f[2]);
  return pgrp != null && pgrp == int.tryParse(f[5]);
}

/// Whether emb is in the terminal's foreground process group.
///
/// `emb … &` still has the terminal on every fd, but a runtime client given
/// `-i -t` then reads and reconfigures it from a background job, and the shell
/// stops the job (SIGTTIN / SIGTTOU) until it is brought forward. When the
/// answer cannot be had the result is false: a plain run always completes.
bool _inForeground() {
  if (Platform.isWindows) return true; // no job control
  try {
    if (Platform.isLinux) {
      return foregroundFromStat(File('/proc/self/stat').readAsStringSync());
    }
    final r = Process.runSync('ps', ['-o', 'pgid=,tpgid=', '-p', '$pid']);
    if (r.exitCode != 0) return false;
    final f = (r.stdout as String).trim().split(RegExp(r'\s+'));
    if (f.length != 2) return false;
    final pgid = int.tryParse(f[0]);
    return pgid != null && pgid == int.tryParse(f[1]);
  } on Object {
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
/// gets an open stdin and a TTY (`-i -t`) when emb's stdin, stdout and stderr
/// are all terminals and emb is the foreground job, so the inner emb, flutter,
/// ninja and git color and prompt as they would natively. A piped, redirected,
/// backgrounded or CI run gets neither and stays plain.
class ContainerLauncher {
  /// [interactive] and [tty] override the terminal detection; null (the
  /// default) asks the process's own stdio at [run] time.
  ContainerLauncher({
    ContainerRunner? run,
    String tool = 'docker',
    bool? interactive,
    bool? tty,
  }) : _run = run ?? containerRunner(),
       _tool = tool,
       _interactive = interactive,
       _tty = tty;

  final ContainerRunner _run;
  final String _tool;
  final bool? _interactive;
  final bool? _tty;

  /// The container runtime argv (everything after the executable):
  ///
  /// ```text
  /// run --rm [-i] [-t] [-v mount…] [-w workdir] -e EMB_IN_CONTAINER=1
  ///   <image> emb <embArgs> --exec-native
  /// ```
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
    // `-i -t` together or not at all, and only when all of these hold:
    //  * stdin is a terminal. A TTY with no `-i` gives the container a stdin
    //    that is open and never written to: a read inside blocks forever,
    //    where without `-t` it got EOF.
    //  * stdout and stderr are terminals. `-t` merges them, so
    //    `emb … 2>err.log` would leave the log empty. `-i` alone is no
    //    fallback: on Ctrl-C the terminal signals emb and the client but not
    //    the container, and a client that outlives emb keeps reading the
    //    terminal out from under the shell. With `-t` Ctrl-C is a byte the
    //    container's own TTY turns into SIGINT.
    //  * emb is the foreground job, see [_inForeground].
    final attach =
        _stdinIsTerminal() &&
        stdout.hasTerminal &&
        stderr.hasTerminal &&
        _inForeground();
    final args = argv(
      image: image,
      embArgs: embArgs,
      mounts: mounts,
      workdir: workdir,
      env: env,
      interactive: _interactive ?? attach,
      tty: _tty ?? attach,
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
