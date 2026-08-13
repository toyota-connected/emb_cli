import 'dart:io';

import 'package:emb_cli/src/pkg/host_provisioner.dart';
import 'package:emb_cli/src/pkg/provision_models.dart';

/// Runs an `apk` subcommand, injectable for tests.
typedef ApkRunner = Future<ProcessResult> Function(List<String> args);

/// Alpine backend: drives `apk` (apk-tools) directly.
///
/// Unlike the PackageKit backend, apk needs **no D-Bus, no systemd, and no
/// native bridge** — it is a plain CLI, like the brew/winget backends. The
/// `so:` / `cmd:` / `pc:` virtual-provides model apk uses is the same one
/// `apk_index.dart` already parses for the cross sysroot.
class ApkProvisioner implements HostProvisioner {
  ApkProvisioner({ApkRunner? run, bool interactive = true})
    : _run = run ?? _defaultRun,
      _interactive = interactive;

  final ApkRunner _run;

  /// apk has no polkit-style prompt; kept for interface parity and used only to
  /// shape the not-authorized remediation hint.
  final bool _interactive;

  Set<String>? _installedCache;

  static Future<ProcessResult> _defaultRun(List<String> args) =>
      Process.run('apk', args);

  @override
  String get name => 'apk';

  @override
  Future<bool> isAvailable() async {
    try {
      final r = await _run(['--version']);
      return r.exitCode == 0;
    } on ProcessException {
      return false; // apk not installed (non-Alpine)
    }
  }

  @override
  Future<List<String>?> availableUpdates() async => null; // not reported here

  Future<Set<String>> _installedNames() async {
    if (_installedCache != null) return _installedCache!;
    final r = await _run(['info']); // lists installed package names, one/line
    if (r.exitCode != 0) return _installedCache = const {};
    return _installedCache = _lines(_text(r.stdout)).toSet();
  }

  @override
  Future<Set<String>> missing(Set<String> names) async {
    if (names.isEmpty) return {};
    final installed = await _installedNames();
    return names.where((n) => !installed.contains(n)).toSet();
  }

  @override
  Future<ProvisionPlan> simulate(Set<String> names) async {
    final toGet = await missing(names);
    if (toGet.isEmpty) {
      return ProvisionPlan(requested: names.toList(), toInstall: const []);
    }
    final r = await _run(['add', '--simulate', ...toGet]);
    if (r.exitCode != 0) {
      // Fall back to the not-installed subset.
      return ProvisionPlan(
        requested: names.toList(),
        toInstall: toGet.toList(),
      );
    }
    final wouldInstall = _parseInstalling(r);
    return ProvisionPlan(
      requested: names.toList(),
      toInstall: wouldInstall.where(names.contains).toList(),
      additional: wouldInstall.where((p) => !names.contains(p)).toList(),
    );
  }

  @override
  Future<ProvisionResult> install(
    Set<String> names, {
    void Function(ProvisionProgress progress)? onProgress,
  }) async {
    final toGet = await missing(names);
    if (toGet.isEmpty) return ProvisionResult(installed: names.toList());

    final r = await _run(['add', ...toGet]);
    _installedCache = null; // invalidate after mutation
    if (r.exitCode == 0) {
      for (final pkg in _parseInstalling(r)) {
        onProgress?.call(ProvisionProgress(label: pkg));
      }
      return ProvisionResult(installed: names.toList());
    }

    final err = _text(r.stderr).trim();
    final kind = _classify(err);
    final hint = kind == ProvisionFailure.notAuthorized && !_interactive
        ? ' (run as root)'
        : '';
    return ProvisionResult(
      installed: const [],
      failed: toGet.toList(),
      message: (err.isEmpty ? 'apk add failed' : err) + hint,
      kind: kind,
    );
  }

  @override
  Future<void> dispose() async {}

  static final _installingRe = RegExp(r'Installing (\S+)');

  List<String> _parseInstalling(ProcessResult r) => [
    for (final m in _installingRe.allMatches(
      '${_text(r.stdout)}\n${_text(r.stderr)}',
    ))
      m.group(1)!,
  ];

  static ProvisionFailure _classify(String err) {
    final e = err.toLowerCase();
    if (e.contains('permission denied') || e.contains('need root')) {
      return ProvisionFailure.notAuthorized;
    }
    if (e.contains('unable to select') ||
        e.contains('no such package') ||
        e.contains('not found')) {
      return ProvisionFailure.unresolved;
    }
    return ProvisionFailure.other;
  }

  static String _text(Object? out) => out is String ? out : '$out';

  static Iterable<String> _lines(String s) =>
      s.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty);
}
