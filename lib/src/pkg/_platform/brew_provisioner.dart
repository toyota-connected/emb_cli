import 'package:brew_dart/brew_dart.dart';
import 'package:emb_cli/src/pkg/host_provisioner.dart';
import 'package:emb_cli/src/pkg/provision_models.dart';

/// macOS (and Linux-brew) backend: drives Homebrew via `brew_dart`.
///
/// Homebrew has no D-Bus-style transaction; `installAll` batches the install
/// with bounded concurrency, which is still a single coalesced operation from
/// the caller's perspective.
class BrewProvisioner implements HostProvisioner {
  /// Creates a provisioner.
  ///
  /// When [interactive] is false, `NONINTERACTIVE=1` is set on every `brew`
  /// invocation, which is Homebrew's own opt-out: it suppresses prompts,
  /// including the sudo password prompt some formulae trigger, and fails
  /// instead of waiting. This is the closest analogue to PackageKit's
  /// `interactive` hint.
  ///
  /// An injected [brew] is used as-is; the caller owns its configuration.
  BrewProvisioner({Brew? brew, bool interactive = true})
    : _brew = brew ?? Brew(cli: BrewCli(defaultEnv: _envFor(interactive)));

  static Map<String, String> _envFor(bool interactive) =>
      interactive ? const {} : const {'NONINTERACTIVE': '1'};

  final Brew _brew;
  Set<String>? _installedCache;

  @override
  String get name => 'brew';

  @override
  Future<bool> isAvailable() => _brew.isInstalled();

  @override
  Future<List<String>?> availableUpdates() async => null; // not reported here

  Future<Set<String>> _installedNames() async =>
      _installedCache ??= (await _brew.listNames()).toSet();

  @override
  Future<Set<String>> missing(Set<String> names) async {
    if (names.isEmpty) return {};
    final installed = await _installedNames();
    return names.where((n) => !installed.contains(n)).toSet();
  }

  @override
  Future<ProvisionPlan> simulate(Set<String> names) async {
    final toGet = await missing(names);
    return ProvisionPlan(requested: names.toList(), toInstall: toGet.toList());
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
    final batch = await _brew.installAll(
      toGet.toList(),
      parallel: true,
      onEach: (pkg, result) => onProgress?.call(ProvisionProgress(label: pkg)),
    );
    _installedCache = null; // invalidate after mutation
    return ProvisionResult(
      installed: batch.succeededPackages,
      failed: batch.failedPackages,
      message: batch.allSucceeded
          ? null
          : 'Failed: ${batch.failedPackages.join(", ")}',
    );
  }

  @override
  Future<void> dispose() async {}
}
