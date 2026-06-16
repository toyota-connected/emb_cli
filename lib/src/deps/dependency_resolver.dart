import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:emb_cli/src/host/host_info.dart';
import 'package:emb_cli/src/manifest/emb_manifest.dart';
import 'package:emb_cli/src/pkg/host_provisioner.dart';

/// The coalesced union of host OS package dependencies across a set of
/// manifests, evaluated for one [HostInfo].
class CoalescedDeps {
  CoalescedDeps({
    required this.host,
    required this.packages,
    required this.byComponent,
    required this.skipped,
  });

  /// The host the union was computed for.
  final HostInfo host;

  /// The de-duplicated, sorted union of required package names.
  final List<String> packages;

  /// Per-component contribution: component id → packages it contributed.
  final Map<String, List<String>> byComponent;

  /// Component ids skipped because they do not apply to [host] (unsupported
  /// arch/host-type).
  final List<String> skipped;

  bool get isEmpty => packages.isEmpty;

  /// A stable content hash over the host identity and the required package
  /// set, suitable as a CI cache key. Changing the host or the package set
  /// changes the hash; component ordering does not.
  late final String contentHash = _hash();

  String _hash() {
    final material = [
      host.os.name,
      host.machineArch,
      host.hostType,
      host.versionId,
      ...packages,
    ].join('\n');
    return sha256.convert(utf8.encode(material)).toString();
  }
}

/// The result of filtering a [CoalescedDeps] against the live system: the
/// subset still missing.
class FilteredDeps {
  const FilteredDeps({
    required this.required,
    required this.missing,
    required this.contentHash,
  });

  /// The full required union (for reference / cache key).
  final List<String> required;

  /// The subset of [required] not currently installed — what will actually
  /// be installed.
  final List<String> missing;

  /// The coalesced content hash (cache key).
  final String contentHash;

  bool get isSatisfied => missing.isEmpty;
}

/// Coalesces and filters host dependencies across manifests for a host.
///
/// This is the heart of the "coalesce → filter → install" model: instead of
/// the legacy per-component `sudo … install` strings run one at a time, the
/// union is gathered once, de-duplicated, then reduced to the not-yet-present
/// subset so a single transaction can install everything at once.
class DependencyResolver {
  const DependencyResolver(this.host);

  final HostInfo host;

  /// Coalesce the applicable dependencies from [manifests].
  ///
  /// A component is included only when it applies to [host]: its
  /// `supported_host_types` (when non-empty) must match, and its
  /// `supported_archs` (when non-empty) must include this arch. Within an
  /// included component, each dependency rule is further matched by
  /// arch/distro/version (legacy schema) before its packages are contributed.
  CoalescedDeps coalesce(Iterable<EmbManifest> manifests) {
    final union = <String>{};
    final byComponent = <String, List<String>>{};
    final skipped = <String>[];

    for (final m in manifests) {
      if (!_applies(m)) {
        skipped.add(m.id);
        continue;
      }
      final pkgs = m.deps.resolve(host);
      if (pkgs.isEmpty) continue;
      byComponent[m.id] = pkgs;
      union.addAll(pkgs);
    }

    final sorted = union.toList()..sort();
    return CoalescedDeps(
      host: host,
      packages: sorted,
      byComponent: byComponent,
      skipped: skipped,
    );
  }

  /// Filter [coalesced] against the live system using [provisioner],
  /// returning the still-missing subset (single `missing()` round-trip).
  Future<FilteredDeps> filter(
    CoalescedDeps coalesced,
    HostProvisioner provisioner,
  ) async {
    final missing = await provisioner.missing(coalesced.packages.toSet());
    final sortedMissing = missing.toList()..sort();
    return FilteredDeps(
      required: coalesced.packages,
      missing: sortedMissing,
      contentHash: coalesced.contentHash,
    );
  }

  bool _applies(EmbManifest m) {
    if (m.supportedHostTypes.isNotEmpty &&
        !host.matchesHostType(m.supportedHostTypes)) {
      return false;
    }
    if (m.supportedArchs.isNotEmpty && !host.supportsArch(m.supportedArchs)) {
      return false;
    }
    return true;
  }
}
