import 'dart:io';

import 'package:emb_cli/src/cross/process_runner.dart';

/// Outcome of a deploy push.
class DeployResult {
  const DeployResult({required this.success, this.message});
  final bool success;
  final String? message;
}

/// rsync a runnable bundle to a board over SSH and (optionally) run it. All
/// SSH/rsync invocation goes through the injectable [ProcessRunner] seam, so
/// the argv is unit-tested without a real board.
class Deployer {
  Deployer({ProcessRunner runProcess = defaultProcessRunner})
    : _run = runProcess;

  final ProcessRunner _run;

  /// rsync `<localDir>/` → `<host>:<destDir>/` — archive, compress,
  /// delete-extraneous. [host] is `user@host`; [port] / [opts] tune SSH.
  Future<DeployResult> push(
    Directory localDir, {
    required String host,
    required String destDir,
    int port = 22,
    String? opts,
  }) async {
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
      message: r.exitCode == 0 ? null : 'rsync: ${r.stderr}',
    );
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
