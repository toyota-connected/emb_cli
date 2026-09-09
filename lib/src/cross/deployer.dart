import 'dart:io';

import 'package:emb_cli/src/cross/cross_target.dart' show DeviceTransport;
import 'package:emb_cli/src/cross/process_runner.dart';

export 'package:emb_cli/src/cross/cross_target.dart' show DeviceTransport;

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

/// A board to deploy to, and how to reach it.
///
/// The [DeployTarget.transport] picks the argv the [Deployer] builds; the rest
/// of the fields are the per-transport addressing. Constructed from the
/// manifest's device block plus the `--deploy` value, so every deploy path
/// takes exactly one of these rather than threading `host`/`port`/`opts`
/// through each call.
class DeployTarget {
  /// An SSH board: [host] is `user@host`, [port]/[opts] tune `ssh`/`rsync -e`.
  const DeployTarget.ssh(this.host, {this.port = 22, this.opts})
    : transport = DeviceTransport.ssh,
      serial = null;

  /// An adb board. [serial] is `adb -s <serial>`; null means adb's own
  /// default, which requires exactly one connected device.
  const DeployTarget.adb({this.serial})
    : transport = DeviceTransport.adb,
      host = null,
      port = 22,
      opts = null;

  /// Parse a `--deploy` value against a manifest [transport]/[serial] default.
  ///
  /// `adb` or `adb:<serial>` selects adb whatever the manifest says, so a
  /// target with no device block (every Yocto SDK manifest) still reaches an
  /// adb board. Otherwise the value is an SSH `user@host` — unless the
  /// manifest already said `transport: adb`, in which case it is a serial.
  factory DeployTarget.parse(
    String value, {
    DeviceTransport transport = DeviceTransport.ssh,
    String? serial,
    int port = 22,
    String? opts,
  }) {
    if (value == 'adb') return DeployTarget.adb(serial: serial);
    if (value.startsWith('adb:')) {
      final s = value.substring(4).trim();
      return DeployTarget.adb(serial: s.isEmpty ? serial : s);
    }
    if (transport == DeviceTransport.adb) {
      return DeployTarget.adb(serial: value.isEmpty ? serial : value);
    }
    return DeployTarget.ssh(value, port: port, opts: opts);
  }

  final DeviceTransport transport;

  /// `user@host` for [DeviceTransport.ssh]; null for adb.
  final String? host;

  /// SSH port. Meaningless for adb.
  final int port;

  /// Extra `ssh`/`rsync -e` options. Meaningless for adb.
  final String? opts;

  /// `adb -s <serial>` selector; null for adb's single-device default.
  final String? serial;

  /// How this board is named in logs and error messages.
  String get label => switch (transport) {
    DeviceTransport.ssh => host ?? '<no host>',
    DeviceTransport.adb => serial == null ? 'adb' : 'adb:$serial',
  };
}

/// Outcome of a deploy push.
class DeployResult {
  const DeployResult({required this.success, this.method, this.message});
  final bool success;

  /// Transport used: `rsync`, `tar` (the fallback when the target has no
  /// rsync), or `adb`. Null on failure before a method was chosen.
  final String? method;
  final String? message;
}

/// Push a runnable bundle to a board and (optionally) run it there, over SSH
/// or adb. Every invocation goes through the injectable [ProcessRunner] seam,
/// so the argv is unit-tested without a real board.
class Deployer {
  Deployer({ProcessRunner runProcess = defaultProcessRunner})
    : _run = runProcess;

  final ProcessRunner _run;

  /// Copy `<localDir>/` → `<device>:<destDir>/`.
  ///
  /// Over SSH this uses rsync (archive, compress, delete-extraneous) when the
  /// board has it, else a tar-over-SSH stream needing only `tar` + a shell.
  /// Over adb it is `adb push`, which **overlays** rather than mirrors — see
  /// [_pushAdb].
  Future<DeployResult> push(
    Directory localDir, {
    required DeployTarget device,
    required String destDir,
  }) async {
    if (device.transport == DeviceTransport.adb) {
      return _pushAdb(localDir, device, destDir);
    }
    final host = device.host!;
    if (await _hasRemoteRsync(host, device.port, device.opts)) {
      return _pushRsync(localDir, host, destDir, device.port, device.opts);
    }
    return _pushTar(localDir, host, destDir, device.port, device.opts);
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
    ], output: ProcessOutputMode.stream);
    return DeployResult(
      success: r.exitCode == 0,
      method: 'rsync',
      message: r.exitCode == 0 ? null : 'rsync: ${r.stderr}',
    );
  }

  /// `tar -czf - -C <local> . | ssh <host> 'mkdir -p <dest> && tar -xzf - -C`
  /// `<dest>'` — works on a board with no rsync (just tar + a shell).
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
    final r = await _run('sh', [
      '-c',
      pipeline,
    ], output: ProcessOutputMode.stream);
    return DeployResult(
      success: r.exitCode == 0,
      method: 'tar',
      message: r.exitCode == 0 ? null : 'tar over ssh: ${r.stderr}',
    );
  }

  /// `adb shell mkdir -p <dest>` then `adb push <local>/. <dest>`.
  ///
  /// Unlike the rsync path this **overlays**: adb has no `--delete`, so a file
  /// dropped from the bundle since the last push stays on the board. Deleting
  /// the destination first is not worth the blast radius of an `rm -rf` driven
  /// by a manifest string, so `--deploy-dir` is pushed into as-is and the
  /// caller is told. Use a fresh `--deploy-dir` when a stale asset matters.
  Future<DeployResult> _pushAdb(
    Directory localDir,
    DeployTarget device,
    String destDir,
  ) async {
    final args = _adbArgs(device);
    try {
      final mk = await _run('adb', [
        ...args,
        'shell',
        'mkdir -p ${_shQuote(destDir)}',
      ]);
      if (mk.exitCode != 0) {
        return DeployResult(
          success: false,
          message: 'adb shell mkdir: ${_adbErr(mk)}',
        );
      }
      // `<dir>/.` pushes the *contents* of the bundle; `adb push <dir> <dest>`
      // would nest it as `<dest>/<dir>`.
      final r = await _run('adb', [
        ...args,
        'push',
        '${_slash(localDir.path)}.',
        destDir,
      ], output: ProcessOutputMode.stream);
      return DeployResult(
        success: r.exitCode == 0,
        method: 'adb',
        message: r.exitCode == 0 ? null : 'adb push: ${_adbErr(r)}',
      );
    } on ProcessException catch (e) {
      return DeployResult(success: false, message: _adbMissing(e));
    }
  }

  /// The target's machine arch (`uname -m`, e.g. `aarch64`); null when the
  /// board is unreachable. Used to warn before pushing a wrong-arch bundle.
  Future<String?> remoteArch(DeployTarget device) async {
    final RunResult r;
    try {
      r = switch (device.transport) {
        DeviceTransport.ssh => await _run('ssh', [
          ..._sshArgs(device.port, device.opts),
          device.host!,
          'uname -m',
        ]),
        DeviceTransport.adb => await _run('adb', [
          ..._adbArgs(device),
          'shell',
          'uname -m',
        ]),
      };
    } on ProcessException {
      return null;
    }
    if (r.exitCode != 0) return null;
    // adbd line-ends with CRLF; trim it so the arch compares literally.
    final a = r.stdout.replaceAll('\r', '').trim();
    return a.isEmpty ? null : a;
  }

  /// The argv for running [command] in [destDir] on [device] (consumed by
  /// `--run`, which streams it).
  List<String> runArgv(DeployTarget device, String destDir, String command) {
    final remote = 'cd ${_shQuote(destDir)} && $command';
    return switch (device.transport) {
      DeviceTransport.ssh => [
        'ssh',
        ..._sshArgs(device.port, device.opts),
        device.host!,
        remote,
      ],
      // adb joins its trailing argv into one shell string, so the whole
      // command is passed as a single argument rather than pre-split.
      DeviceTransport.adb => ['adb', ..._adbArgs(device), 'shell', remote],
    };
  }

  List<String> _adbArgs(DeployTarget device) => [
    if (device.serial != null && device.serial!.isNotEmpty) ...[
      '-s',
      device.serial!,
    ],
  ];

  /// adb reports most failures on stdout with exit 1, so fall back to it when
  /// stderr is empty.
  String _adbErr(RunResult r) {
    final e = r.stderr.trim();
    return e.isNotEmpty ? e : r.stdout.trim();
  }

  String _adbMissing(ProcessException e) =>
      'adb not found on PATH (${e.message}) — install the platform-tools '
      'package that provides adb, or use the ssh transport.';

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
