import 'package:emb_cli/src/host/host_info.dart';
import 'package:emb_cli/src/pkg/_platform/apk_provisioner.dart';
import 'package:emb_cli/src/pkg/_platform/brew_provisioner.dart';
import 'package:emb_cli/src/pkg/_platform/winget_provisioner.dart';
import 'package:emb_cli/src/pkg/packagekit_provisioner.dart';
import 'package:emb_cli/src/pkg/provision_models.dart';

/// A host OS package provisioner.
///
/// Implementations wrap exactly one platform backend — PackageKit on Linux,
/// Homebrew on macOS, WinGet on Windows — and are only ever instantiated on
/// their own OS (Dart has no OS-conditional dependencies, so selection happens
/// at runtime via [HostProvisioner.forHost]).
///
/// The contract is name-centric so the coalesce/filter stage can work in plain
/// package names: [missing] computes the not-yet-installed subset, [simulate]
/// dry-runs, and [install] performs a single batched transaction.
abstract class HostProvisioner {
  /// Backend name for diagnostics (`packagekit`, `brew`, `winget`).
  String get name;

  /// Select the provisioner for [host].
  ///
  /// Returns the platform-appropriate backend: `apk` on Alpine (no systemd),
  /// PackageKit on other Linux, Homebrew on macOS, WinGet on Windows.
  ///
  /// [interactive] governs whether the backend may prompt the user to
  /// authorize a privileged operation. Every backend accepts it, even where
  /// the underlying tool exposes no equivalent, so the interface does not
  /// diverge per platform.
  static HostProvisioner forHost(HostInfo host, {bool interactive = true}) {
    switch (host.os) {
      case HostOs.linux:
        // Alpine (musl/OpenRC) has no systemd/PackageKit — drive apk directly,
        // which also needs none of the sd-bus native bridge.
        if (host.hostType == 'alpine') {
          return ApkProvisioner(interactive: interactive);
        }
        return PackageKitProvisioner(interactive: interactive);
      case HostOs.macos:
        return BrewProvisioner(interactive: interactive);
      case HostOs.windows:
        return WingetProvisioner(interactive: interactive);
    }
  }

  /// Whether the backend daemon/CLI is reachable on this host.
  Future<bool> isAvailable();

  /// Package names with an available update, per the backend's last cache
  /// refresh; null when the backend can't report it (return null rather than
  /// guessing), and an empty list means "up to date".
  Future<List<String>?> availableUpdates();

  /// Return the subset of [names] that is NOT currently installed. This is the
  /// "filter" primitive used by the coalesce/filter stage.
  Future<Set<String>> missing(Set<String> names);

  /// Dry-run: resolve what installing [names] would change, without modifying
  /// the system.
  Future<ProvisionPlan> simulate(Set<String> names);

  /// Install [names] in a single transaction. [onProgress] receives live
  /// progress events when the backend reports them.
  Future<ProvisionResult> install(
    Set<String> names, {
    void Function(ProvisionProgress progress)? onProgress,
  });

  /// Release any held resources (daemon connections, COM handles).
  Future<void> dispose();
}
