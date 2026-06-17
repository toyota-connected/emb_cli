import 'dart:io';

import 'package:emb_cli/src/cross/process_runner.dart';

/// Whether a [bundleArch] (a binary/triple arch) is compatible with a board's
/// `uname -m` [machine], tolerating the usual aliases (arm64/aarch64,
/// amd64/x86_64, armv7*/armhf). Unknown arches compare literally.
bool archMatches(String bundleArch, String machine) {
  String n(String s) => switch (s.toLowerCase()) {
    'arm64' || 'aarch64' => 'aarch64',
    'amd64' || 'x86_64' || 'x64' => 'x86_64',
    'armv7l' || 'armv7hf' || 'armhf' || 'arm' => 'arm',
    'riscv64' || 'rv64' => 'riscv64',
    final v => v,
  };
  return n(bundleArch) == n(machine);
}

/// Outcome of a deploy push.
class DeployResult {
  const DeployResult({required this.success, this.method, this.message});
  final bool success;

  /// Transport used: `rsync` or `tar` (the fallback when the target has no
  /// rsync). Null on failure before a method was chosen.
  final String? method;
  final String? message;
}

/// rsync a runnable bundle to a board over SSH and (optionally) run it. All
/// SSH/rsync invocation goes through the injectable [ProcessRunner] seam, so
/// the argv is unit-tested without a real board.
class Deployer {
  Deployer({ProcessRunner runProcess = defaultProcessRunner})
    : _run = runProcess;

  final ProcessRunner _run;

  /// Copy `<localDir>/` → `<host>:<destDir>/`. Uses rsync (archive, compress,
  /// delete-extraneous) when the target has it; otherwise falls back to a
  /// tar-over-SSH stream that needs only `tar` + a shell on the board. [host]
  /// is `user@host`; [port] / [opts] tune SSH.
  Future<DeployResult> push(
    Directory localDir, {
    required String host,
    required String destDir,
    int port = 22,
    String? opts,
  }) async {
    if (await _hasRemoteRsync(host, port, opts)) {
      return _pushRsync(localDir, host, destDir, port, opts);
    }
    return _pushTar(localDir, host, destDir, port, opts);
  }

  Future<bool> _hasRemoteRsync(String host, int port, String? opts) async {
    final r = await _run('ssh', [
      ..._sshArgs(port, opts),
      host,
      'command -v rsync >/dev/null 2>&1',
    ]);
    return r.exitCode == 0;
  }

  Future<DeployResult> _pushRsync(
    Directory localDir,
    String host,
    String destDir,
    int port,
    String? opts,
  ) async {
    // rsync won't create the remote parent dirs; do it first.
    final mk = await _run('ssh', [
      ..._sshArgs(port, opts),
      host,
      'mkdir -p ${_shQuote(destDir)}',
    ]);
    if (mk.exitCode != 0) {
      return DeployResult(success: false, message: 'ssh mkdir: ${mk.stderr}');
    }
    final r = await _run('rsync', [
      '-az',
      '--delete',
      '-e',
      _sshTransport(port, opts),
      _slash(localDir.path),
      '$host:${_slash(destDir)}',
    ]);
    return DeployResult(
      success: r.exitCode == 0,
      method: 'rsync',
      message: r.exitCode == 0 ? null : 'rsync: ${r.stderr}',
    );
  }

  /// `tar -czf - -C <local> . | ssh <host> 'mkdir -p <dest> && tar -xzf - -C
  /// <dest>'` — works on a board with no rsync (just tar + a shell).
  Future<DeployResult> _pushTar(
    Directory localDir,
    String host,
    String destDir,
    int port,
    String? opts,
  ) async {
    final ssh = ['ssh', ..._sshArgs(port, opts), host].join(' ');
    final remote = 'mkdir -p "$destDir" && tar -xzf - -C "$destDir"';
    final pipeline =
        'tar -czf - -C ${_shQuote(localDir.path)} . | $ssh ${_shQuote(remote)}';
    final r = await _run('sh', ['-c', pipeline]);
    return DeployResult(
      success: r.exitCode == 0,
      method: 'tar',
      message: r.exitCode == 0 ? null : 'tar over ssh: ${r.stderr}',
    );
  }

  /// The target's machine arch (`uname -m`, e.g. `aarch64`); null if the host
  /// is unreachable. Used to warn before pushing a wrong-arch bundle.
  Future<String?> remoteArch(String host, {int port = 22, String? opts}) async {
    final r = await _run('ssh', [..._sshArgs(port, opts), host, 'uname -m']);
    if (r.exitCode != 0) return null;
    final a = '${r.stdout}'.trim();
    return a.isEmpty ? null : a;
  }

  /// The argv for running [command] in [destDir] on [host] over SSH (consumed
  /// by `--run`, which streams it).
  List<String> runArgv(
    String host,
    String destDir,
    String command, {
    int port = 22,
    String? opts,
  }) => [
    'ssh',
    ..._sshArgs(port, opts),
    host,
    'cd ${_shQuote(destDir)} && $command',
  ];

  List<String> _sshArgs(int port, String? opts) => [
    if (port != 22) ...['-p', '$port'],
    if (opts != null && opts.trim().isNotEmpty)
      ...opts.trim().split(RegExp(r'\s+')),
  ];

  /// rsync's `-e` transport string.
  String _sshTransport(int port, String? opts) => [
    'ssh',
    if (port != 22) '-p $port',
    if (opts != null && opts.trim().isNotEmpty) opts.trim(),
  ].join(' ');

  String _slash(String path) => path.endsWith('/') ? path : '$path/';
  String _shQuote(String s) => "'${s.replaceAll("'", r"'\''")}'";
}
