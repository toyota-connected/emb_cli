import 'package:emb_cli/src/host/host_info.dart';
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
  /// Only the Linux (PackageKit) backend is compiled into the default build.
  /// The macOS (Homebrew) and Windows (WinGet) backends live in
  /// `lib/src/pkg/_platform/` and are wired in per-OS builds that add the
  /// corresponding dependency — see that folder's README. Selecting an
  /// uncompiled backend throws [UnsupportedError].
  static HostProvisioner forHost(HostInfo host) {
    switch (host.os) {
      case HostOs.linux:
        return PackageKitProvisioner();
      case HostOs.macos:
      case HostOs.windows:
        throw UnsupportedError(
          'The ${host.os.configToken} package backend is not compiled into '
          'this build. Build emb on ${host.os.name} with the platform backend '
          'enabled (see lib/src/pkg/_platform/README.md).',
        );
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
