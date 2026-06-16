import 'package:emb_cli/src/pkg/host_provisioner.dart';
import 'package:emb_cli/src/pkg/provision_models.dart';
// NativeWingetBridge is not re-exported by the winget_dart barrel; it is the
// only concrete bridge for real Windows use.
// ignore: implementation_imports
import 'package:winget_dart/src/bridge/native_winget_bridge.dart';
import 'package:winget_dart/winget_dart.dart';

/// Windows backend: drives the Windows Package Manager (WinGet) through the
/// `Microsoft.Management.Deployment` COM interface via `winget_dart`.
///
/// On Windows, manifest "package names" are WinGet package ids
/// (e.g. `Kitware.CMake`). WinGet installs one id per transaction, so the
/// batch is performed as a sequence of installs with aggregated results.
class WingetProvisioner implements HostProvisioner {
  WingetProvisioner({WingetBridge? bridge}) : _bridge = bridge;

  final WingetBridge? _bridge;
  WgClient? _client;

  @override
  String get name => 'winget';

  Future<WgClient> _connect() async =>
      _client ??= await WgClient.connect(_bridge ?? NativeWingetBridge());

  @override
  Future<bool> isAvailable() async {
    try {
      await _connect();
      return true;
    } on Object {
      return false;
    }
  }

  @override
  Future<Set<String>> missing(Set<String> names) async {
    if (names.isEmpty) return {};
    final client = await _connect();
    final installed = await client.listInstalled().result;
    final installedIds = installed.map((p) => p.id).toSet();
    return names.where((n) => !installedIds.contains(n)).toSet();
  }

  @override
  Future<ProvisionPlan> simulate(Set<String> names) async {
    final toGet = await missing(names);
    if (toGet.isEmpty) {
      return ProvisionPlan(requested: names.toList(), toInstall: const []);
    }
    final client = await _connect();
    final toInstall = <String>[];
    final additional = <String>[];
    for (final id in toGet) {
      try {
        final plan = await client.simulateInstall(id);
        for (final pkg in plan.installing) {
          (pkg.id == id ? toInstall : additional).add(pkg.id);
        }
        if (plan.installing.isEmpty) toInstall.add(id);
      } on Object {
        toInstall.add(id);
      }
    }
    return ProvisionPlan(
      requested: names.toList(),
      toInstall: toInstall,
      additional: additional,
    );
  }

  @override
  Future<ProvisionResult> install(
    Set<String> names, {
    void Function(ProvisionProgress progress)? onProgress,
  }) async {
    final toGet = await missing(names);
    if (toGet.isEmpty) {
      return ProvisionResult(installed: names.toList());
    }
    final client = await _connect();
    final installed = <String>[];
    final failed = <String>[];
    for (final id in toGet) {
      final tx = client.installPackage(id);
      final sub = tx.progress.listen(
        (p) => onProgress?.call(
          ProvisionProgress(label: '$id ${p.label}', percent: p.percent),
        ),
      );
      try {
        await tx.result;
        installed.add(id);
      } on Object {
        failed.add(id);
      } finally {
        await sub.cancel();
      }
    }
    return ProvisionResult(
      installed: installed,
      failed: failed,
      message: failed.isEmpty ? null : 'Failed: ${failed.join(", ")}',
    );
  }

  @override
  Future<void> dispose() async {
    await _client?.close();
    _client = null;
  }
}
