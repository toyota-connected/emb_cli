import 'package:emb_cli/src/pkg/host_provisioner.dart';
import 'package:emb_cli/src/pkg/provision_models.dart';
import 'package:packagekit_dart/packagekit_dart.dart';

/// Linux backend: drives the PackageKit daemon (dnf/apt/zypper/…) over D-Bus
/// via `packagekit_dart`.
///
/// Package names are resolved to backend package-ids before any
/// install/simulate, because PackageKit operates on fully-qualified ids
/// (`name;version;arch;data`). Names that don't match a package directly are
/// resolved through `WhatProvides`, so virtual provides / alternate names
/// (`pkg-config` → `pkgconf-pkg-config`, `libjpeg-devel` →
/// `libjpeg-turbo-devel`, `go` → `golang`, …) are handled the way
/// `dnf install` would.
class PackageKitProvisioner implements HostProvisioner {
  PackageKitProvisioner();

  PkClient? _client;

  static const _installableFilters = [
    PkFilter.notInstalled,
    PkFilter.arch,
    PkFilter.newest,
  ];

  @override
  String get name => 'packagekit';

  /// Connect to the PackageKit daemon, caching the client.
  ///
  /// Right after boot (notably under WSL) the system bus / on-demand
  /// activation can be momentarily not-ready, surfacing as a
  /// [PkServiceUnavailableException] that fails near-instantly (no daemon spawn
  /// is even attempted). Give it a single retry after a short delay so a
  /// startup race doesn't make the backend look permanently unavailable.
  Future<PkClient> _connect() async {
    try {
      return _client ??= await PkClient.connect();
    } on PkServiceUnavailableException {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      return _client ??= await PkClient.connect();
    }
  }

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
  Future<List<String>?> availableUpdates() async {
    final client = await _connect();
    // `GetUpdates` reflects the last cache refresh (we don't refresh here, to
    // keep doctor read-only/fast). Distinct names, sorted for stable output.
    final pkgs = await _collectPackages(client.getUpdates());
    final names = {for (final p in pkgs) p.id.name}.toList()..sort();
    return names;
  }

  @override
  Future<Set<String>> missing(Set<String> names) async {
    if (names.isEmpty) return {};
    final client = await _connect();
    // A name is satisfied if an installed package matches it directly, or if
    // an installed package *provides* it.
    final installedByName = await _resolveNames(client, names.toList(), const [
      PkFilter.installed,
    ]);
    final satisfied = installedByName.keys.toSet();
    for (final n in names.difference(satisfied)) {
      if (await _providesInstalled(client, n)) satisfied.add(n);
    }
    return names.difference(satisfied);
  }

  @override
  Future<ProvisionPlan> simulate(Set<String> names) async {
    final toGet = await missing(names);
    if (toGet.isEmpty) {
      return ProvisionPlan(requested: names.toList(), toInstall: const []);
    }
    final client = await _connect();
    final res = await _resolveInstallable(client, toGet);
    if (res.ids.isEmpty) {
      return ProvisionPlan(
        requested: names.toList(),
        toInstall: const [],
        unresolved: res.unresolved,
      );
    }
    final plan = await client.simulateInstall(res.ids);
    final topIds = res.ids.toSet();
    final toInstall = <String>[];
    final additional = <String>[];
    for (final pkg in plan.installing) {
      (topIds.contains(pkg.id.raw) ? toInstall : additional).add(pkg.id.name);
    }
    return ProvisionPlan(
      requested: names.toList(),
      toInstall: toInstall.isEmpty ? _idNames(res.ids) : toInstall,
      additional: additional,
      unresolved: res.unresolved,
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
    final res = await _resolveInstallable(client, toGet);
    if (res.ids.isEmpty) {
      return ProvisionResult(
        installed: const [],
        failed: res.unresolved,
        message:
            'No installable packages found for: '
            '${res.unresolved.join(", ")}',
      );
    }

    final tx = client.installPackages(res.ids);
    final sub = tx.progress.listen((p) {
      final label = p.packageId.isNotEmpty
          ? p.packageId.split(';').first
          : p.status.name;
      onProgress?.call(
        ProvisionProgress(
          label: label,
          percent: p.percentageKnown ? p.percentage : null,
        ),
      );
    });
    final errors = <String>[];
    final errSub = tx.errors.listen((e) => errors.add(e.details));

    try {
      final result = await tx.result;
      await sub.cancel();
      await errSub.cancel();
      if (result.success) {
        final installed = _idNames(res.ids);
        return ProvisionResult(
          installed: installed,
          failed: res.unresolved,
          message: res.unresolved.isEmpty
              ? null
              : 'Unresolved packages: ${res.unresolved.join(", ")}',
        );
      }
      return ProvisionResult(
        installed: const [],
        failed: toGet.toList(),
        message: errors.isEmpty ? 'Install failed' : errors.join('; '),
      );
    } on Object catch (e) {
      await sub.cancel();
      await errSub.cancel();
      return ProvisionResult(
        installed: const [],
        failed: toGet.toList(),
        message: '$e',
      );
    }
  }

  @override
  Future<void> dispose() async {
    await _client?.close();
    _client = null;
  }

  /// Whether any *installed* package provides [value]. Uses `WhatProvides` so
  /// provide-only/alternate names count as satisfied.
  Future<bool> _providesInstalled(PkClient client, String value) async {
    final tx = client.whatProvides(
      [value],
      filters: const [PkFilter.installed],
    );
    var any = false;
    await for (final _ in tx.packages) {
      any = true;
    }
    await tx.result;
    return any;
  }

  /// Resolve [names] to installable package-ids, falling back to
  /// `WhatProvides` for names with no direct package match. A provides lookup
  /// is only accepted when it yields a single distinct provider package
  /// (ambiguous providers are left [_Resolution.unresolved] rather than
  /// guessing).
  Future<_Resolution> _resolveInstallable(
    PkClient client,
    Set<String> names,
  ) async {
    final byName = await _resolveNames(
      client,
      names.toList(),
      _installableFilters,
    );
    final ids = <String>{...byName.values};
    final unresolved = <String>[];

    for (final n in names.difference(byName.keys.toSet())) {
      final providers = await _collectPackages(
        client.whatProvides([n], filters: _installableFilters),
      );
      final byProvider = <String, String>{}; // provider name → newest id
      for (final p in providers) {
        byProvider[p.id.name] = p.id.raw;
      }
      if (byProvider.length == 1) {
        ids.add(byProvider.values.first);
      } else {
        unresolved.add(n); // none, or ambiguous
      }
    }
    return _Resolution(ids.toList(), unresolved);
  }

  /// Resolve [names] to a map of name → newest package-id for the given
  /// [filters], draining the resolve transaction.
  Future<Map<String, String>> _resolveNames(
    PkClient client,
    List<String> names,
    List<PkFilter> filters,
  ) async {
    if (names.isEmpty) return {};
    final tx = client.resolve(names, filters: filters);
    final found = <String, String>{};
    await for (final pkg in tx.packages) {
      found[pkg.id.name] = pkg.id.raw;
    }
    await tx.result;
    return found;
  }

  Future<List<PkPackage>> _collectPackages(PkTransaction tx) async {
    final out = <PkPackage>[];
    await for (final p in tx.packages) {
      out.add(p);
    }
    await tx.result;
    return out;
  }

  List<String> _idNames(List<String> ids) =>
      ids.map((id) => id.split(';').first).toList();
}

/// Resolved installable ids plus the names that could not be resolved.
class _Resolution {
  const _Resolution(this.ids, this.unresolved);
  final List<String> ids;
  final List<String> unresolved;
}
