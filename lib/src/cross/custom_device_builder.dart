import 'package:emb_cli/src/cross/cross_target.dart';
import 'package:emb_cli/src/cross/deployer.dart';
import 'package:emb_cli/src/cross/run_command.dart';

/// Thrown when a target cannot produce a usable device entry.
class CustomDeviceException implements Exception {
  const CustomDeviceException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Builds the Flutter `custom-devices` JSON entry for a board target.
///
/// Flutter drives a custom device through five command arrays. emb derives all
/// of them from the target's [DeployTarget] and deploy dir rather than letting
/// a board file restate them, so a registered device always describes the
/// deployment `emb cross --deploy` actually performs.
///
/// The division of labour with `--deploy` matters: `--deploy` puts the
/// embedder, the engine and `lib/` on the board once, and the device entry's
/// `install` then only refreshes `data/flutter_assets` on every run and hot
/// restart — which is exactly the directory Flutter hands over as
/// `${localPath}`.
///
/// [deployDir] is the bundle root on the board (`--deploy-dir`), [binName] the
/// embedder inside it, and [triple] the target triple used to pick Flutter's
/// `platform` value.
Map<String, dynamic> buildCustomDevice({
  required CustomDeviceSpec spec,
  required DeployTarget device,
  required String deployDir,
  required String binName,
  String? triple,
  String? targetName,
  List<String>? runCommand,
  Map<String, String> runEnv = const {},
  Set<String>? unknowns,
}) {
  if (spec.id.trim().isEmpty) {
    throw const CustomDeviceException(
      'custom_device.id is required (it is what `flutter run -d <id>` names).',
    );
  }
  if (deployDir.trim().isEmpty || deployDir.trim() == '/') {
    // The install command clears `<deployDir>/data/flutter_assets` before
    // copying; refuse a value that would aim that at the filesystem root.
    throw const CustomDeviceException(
      'a deploy dir is required to build a custom device (got an empty or '
      'root path).',
    );
  }
  if (device.transport == DeviceTransport.ssh &&
      (device.host == null || device.host!.trim().isEmpty)) {
    throw const CustomDeviceException(
      'the ssh transport needs a host: set cross.sysroot.host, or select adb '
      'with cross.sysroot.transport.',
    );
  }

  final dir = deployDir.trim();
  final assets = '$dir/data/flutter_assets';
  final platform = spec.platform ?? _platformFor(triple);
  final vars = {'embedder': binName, 'deploy_dir': '.'};
  final runCmd = runCmdString(
    applyRunVars(runCommand ?? defaultRunTemplate, vars, unknowns: unknowns),
    env: runEnv,
  );
  // `${engineOptions}` is Flutter's placeholder, interpolated at
  // launch with --enable-dart-profiling, the vm-service flags hot
  // reload needs, and so on. It stays literal in the written JSON.
  final runDebugCmd = 'cd ${_q(dir)} && $runCmd \${engineOptions}';

  return <String, dynamic>{
    'id': spec.id,
    'label': spec.label ?? spec.id,
    'sdkNameAndVersion':
        spec.sdkNameAndVersion ??
        [
          if (targetName != null) targetName,
          if (triple != null) '($triple)',
        ].join(' ').trim(),
    if (platform != null) 'platform': platform,
    'enabled': spec.enabled,
    'ping': _ping(device),
    'install': _install(device, assets),
    'uninstall': _remote(device, 'rm -rf ${_q(assets)}'),
    'runDebug': _remote(device, runDebugCmd),
    'forwardPort': _forwardPort(device),
    'forwardPortSuccessRegex': 'Port forwarding success',
    'screenshot': null,
  };
}

/// Flutter accepts only these two; anything else must be omitted rather than
/// guessed, or `flutter run` rejects the whole config file.
String? _platformFor(String? triple) {
  if (triple == null) return null;
  final t = triple.toLowerCase();
  if (t.startsWith('aarch64') || t.startsWith('arm64')) return 'linux-arm64';
  if (t.startsWith('x86_64') || t.startsWith('amd64')) return 'linux-x64';
  return null;
}

/// Proving the transport works beats an ICMP ping: it also covers ssh auth and
/// adb authorization, which are what actually break. Exit code alone decides,
/// so no `pingSuccessRegex` is emitted.
List<String> _ping(DeployTarget d) => switch (d.transport) {
  DeviceTransport.ssh => ['ssh', ..._sshOpts(d), d.host!, 'true'],
  DeviceTransport.adb => ['adb', ..._adbArgs(d), 'shell', 'true'],
};

/// Clear and recreate `data/flutter_assets`, then copy `${localPath}` into it.
///
/// Wrapped in `sh -c` because Flutter runs one argv with no shell, and this
/// genuinely needs two steps: without the clear, an asset deleted from the app
/// since the last run lingers on the board and the next hot restart still
/// serves it.
List<String> _install(DeployTarget d, String assets) {
  final prep = _q('rm -rf ${_q(assets)} && mkdir -p ${_q(assets)}');
  // Flutter runs this script through a shell on the *developer's machine*, so
  // every manifest-sourced value in it is quoted: `host` (cross.sysroot.host),
  // and each element of ssh_opts / adb_serial. Quoting per element, not the
  // joined string, keeps them separate arguments.
  final sshOpts = _sshOpts(d, quoted: true).join(' ');
  final scpOpts = _sshScpOpts(d, quoted: true).join(' ');
  final adbArgs = _adbArgs(d, quoted: true).join(' ');
  final host = d.host == null ? '' : _q(d.host!);
  final script = switch (d.transport) {
    DeviceTransport.ssh =>
      'ssh $sshOpts $host $prep && '
          'scp -r $scpOpts '
          "'\${localPath}'/. $host:${_q(assets)}",
    DeviceTransport.adb =>
      'adb $adbArgs shell $prep && '
          "adb $adbArgs push '\${localPath}'/. ${_q(assets)}",
  };
  return ['sh', '-c', script];
}

/// A single remote shell command over the transport, as one argv.
List<String> _remote(DeployTarget d, String command) => switch (d.transport) {
  DeviceTransport.ssh => ['ssh', ..._sshOpts(d), d.host!, command],
  DeviceTransport.adb => ['adb', ..._adbArgs(d), 'shell', command],
};

/// Flutter needs the forward to be a process it can keep alive and later kill,
/// and to announce itself on stdout.
///
/// `ssh -L` is naturally that process. `adb forward` is not — it returns at
/// once and the forward outlives it — so the adb form blocks on
/// `tail -f /dev/null` to give Flutter something to hold.
List<String> _forwardPort(DeployTarget d) => switch (d.transport) {
  DeviceTransport.ssh => [
    'ssh',
    ..._sshOpts(d),
    '-o',
    'ExitOnForwardFailure=yes',
    '-L',
    r'127.0.0.1:${hostPort}:127.0.0.1:${devicePort}',
    d.host!,
    "echo 'Port forwarding success'; read",
  ],
  DeviceTransport.adb => ['sh', '-c', _adbForward(d)],
};

String _adbForward(DeployTarget d) =>
    'adb ${_adbArgs(d).join(' ')} forward '
    r'tcp:${hostPort} tcp:${devicePort} && '
    "echo 'Port forwarding success' && tail -f /dev/null";

/// `BatchMode=yes` on every ssh: Flutter runs these unattended, and a password
/// prompt would hang the run rather than fail it.
/// emb's own flags stay bare — they are constants, and a readable command in
/// the written config is worth keeping. Only [DeployTarget.opts], which comes
/// from the manifest, is quoted, and per token so a multi-flag string still
/// arrives as separate arguments.
List<String> _sshOpts(DeployTarget d, {bool quoted = false}) => [
  '-o',
  'BatchMode=yes',
  if (d.port != 22) ...['-p', '${d.port}'],
  ...?_extra(d.opts)?.map((o) => quoted ? _q(o) : o),
];

/// scp spells the port `-P`, not `-p`.
List<String> _sshScpOpts(DeployTarget d, {bool quoted = false}) => [
  '-o',
  'BatchMode=yes',
  if (d.port != 22) ...['-P', '${d.port}'],
  ...?_extra(d.opts)?.map((o) => quoted ? _q(o) : o),
];

List<String>? _extra(String? opts) => (opts == null || opts.trim().isEmpty)
    ? null
    : opts.trim().split(RegExp(r'\s+'));

List<String> _adbArgs(DeployTarget d, {bool quoted = false}) => [
  if (d.serial != null && d.serial!.isNotEmpty) ...[
    '-s',
    if (quoted) _q(d.serial!) else d.serial!,
  ],
];

String _q(String s) => "'${s.replaceAll("'", r"'\''")}'";
