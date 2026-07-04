import 'dart:io';

import 'package:emb_cli/src/cross/cross_keys.dart';
import 'package:emb_cli/src/cross/cross_target.dart';
import 'package:emb_cli/src/cross/process_runner.dart';
import 'package:path/path.dart' as p;

/// The directory holding the `Cargo.lock` that governs [start], found by
/// walking up from [start] to the enclosing repository. A crate in a Cargo
/// workspace locks at the workspace root, not beside its own `Cargo.toml`, so a
/// naive `<start>/Cargo.lock` check wrongly concludes "unpinned".
///
/// Returns the first ancestor (including [start]) that has a `Cargo.lock`.
/// Ascent stops at a `.git` boundary — the repo root is the outermost place a
/// lock can live — so it never escapes into an unrelated parent project.
/// Returns null when no lock is found within the repo.
Directory? cargoLockDir(Directory start) {
  var dir = start.absolute;
  while (true) {
    if (File(p.join(dir.path, 'Cargo.lock')).existsSync()) return dir;
    // A `.git` dir or file (submodule/worktree) marks the repo root: search it
    // for the lock above, but don't ascend past it.
    if (FileSystemEntity.typeSync(p.join(dir.path, '.git')) !=
        FileSystemEntityType.notFound) {
      return null;
    }
    final parent = dir.parent;
    if (p.equals(parent.path, dir.path)) return null; // filesystem root
    dir = parent;
  }
}

/// Force every `directory = "..."` line in a `cargo vendor` config to the
/// absolute [vendorDirAbs]. `cargo vendor` echoes back whatever path it was
/// given for the `[source.vendored-sources]` directory; pinning it absolute
/// lets the config be consumed from any `CARGO_HOME`, not just the cwd it was
/// generated in.
String vendorConfig(String cargoStdout, String vendorDirAbs) =>
    cargoStdout.replaceAllMapped(
      RegExp(r'^(\s*directory\s*=\s*)".*"\s*$', multiLine: true),
      (m) => '${m[1]}"$vendorDirAbs"',
    );

/// Outcome of [CargoVendor.vendor] / [CargoVendor.locate]: the `CARGO_HOME` to
/// build a cargo module against offline, or an error.
class CargoVendorResult {
  const CargoVendorResult._(this.cargoHome, this.error);

  factory CargoVendorResult.ok(Directory cargoHome) =>
      CargoVendorResult._(cargoHome, null);
  factory CargoVendorResult.failed(String error) =>
      CargoVendorResult._(null, error);

  /// A `CARGO_HOME` dir whose `config.toml` replaces crates-io with the
  /// vendored sources; set it (plus `--offline`) to build with no network.
  final Directory? cargoHome;
  final String? error;

  bool get ok => error == null;
}

/// Vendors a cargo module's dependency closure into the shared store so an
/// offline build has every crate on disk. A vendored directory is enumerable,
/// diffable, and archivable — unlike a shared `CARGO_HOME` registry cache,
/// whose partial-fetch state can wedge in a way `--offline` cannot self-heal.
class CargoVendor {
  CargoVendor({ProcessRunner run = defaultProcessRunner}) : _run = run;

  final ProcessRunner _run;

  /// The store paths for the module locked by [lockDir]'s `Cargo.lock`,
  /// content-addressed by the lock so an unchanged lock reuses the vendor tree.
  ({Directory vendor, Directory home, File config}) _paths(
    Directory lockDir,
    Directory storeRoot,
  ) {
    final key = contentHash([
      File(p.join(lockDir.path, 'Cargo.lock')).readAsStringSync(),
    ]);
    final base = Directory(p.join(storeRoot.path, 'cargo-vendor', key));
    final home = Directory(p.join(base.path, 'home'));
    return (
      vendor: Directory(p.join(base.path, 'vendor')),
      home: home,
      config: File(p.join(home.path, 'config.toml')),
    );
  }

  /// Locate an already-vendored `CARGO_HOME` for [moduleSrc] under [storeRoot],
  /// or null when it hasn't been vendored (or the module has no lock). Pure
  /// filesystem lookup — never touches the network — so it is safe under
  /// `--offline`.
  Directory? locate({
    required Directory moduleSrc,
    required Directory storeRoot,
  }) {
    final lockDir = cargoLockDir(moduleSrc);
    if (lockDir == null) return null;
    final paths = _paths(lockDir, storeRoot);
    return paths.config.existsSync() && paths.vendor.existsSync()
        ? paths.home
        : null;
  }

  /// Vendor [moduleSrc]'s crates into [storeRoot] (a no-op when already
  /// vendored) and return the `CARGO_HOME` to build against. Runs
  /// `cargo vendor --locked`, so an out-of-date lock is an error rather than a
  /// silent update.
  Future<CargoVendorResult> vendor({
    required Directory moduleSrc,
    required Directory storeRoot,
  }) async {
    final lockDir = cargoLockDir(moduleSrc);
    if (lockDir == null) {
      return CargoVendorResult.failed(
        'no Cargo.lock at or above ${moduleSrc.path} — cargo deps are '
        'unpinned; commit a Cargo.lock so the closure is enumerable',
      );
    }
    final paths = _paths(lockDir, storeRoot);
    if (paths.config.existsSync() && paths.vendor.existsSync()) {
      return CargoVendorResult.ok(paths.home); // cached
    }
    paths.home.createSync(recursive: true);
    final r = await _run(
      'cargo',
      [
        'vendor',
        '--locked',
        '--manifest-path',
        p.join(lockDir.path, 'Cargo.toml'),
        paths.vendor.path,
      ],
      workingDirectory: lockDir.path,
      output: ProcessOutputMode.capture,
    );
    if (r.exitCode != 0) {
      return CargoVendorResult.failed('cargo vendor failed: ${r.stderr}');
    }
    paths.config.writeAsStringSync(vendorConfig(r.stdout, paths.vendor.path));
    return CargoVendorResult.ok(paths.home);
  }
}

/// Vendor every `build: cargo` module of [target] (sources under [manifestDir])
/// into [storeRoot], so an offline build finds their crates on disk. Calls
/// [onModule] with each vendored module name. Returns null on success, or a
/// log-ready error for the first module that fails. A no-op when the target has
/// no cargo modules.
Future<String?> vendorTargetCargo({
  required CrossTarget target,
  required Directory manifestDir,
  required Directory storeRoot,
  required ProcessRunner run,
  void Function(String name)? onModule,
}) async {
  final vendor = CargoVendor(run: run);
  for (final m in target.modules) {
    if (m.build != ModuleBuild.cargo) continue;
    final src = Directory(p.join(manifestDir.path, m.path));
    if (!src.existsSync()) {
      return 'module ${m.name}: source dir not found: ${src.path}';
    }
    final res = await vendor.vendor(moduleSrc: src, storeRoot: storeRoot);
    if (!res.ok) return 'module ${m.name}: ${res.error}';
    onModule?.call(m.name);
  }
  return null;
}

/// Whether [target] has any `build: cargo` module (so a caller knows to check
/// for `cargo` and vendor before an offline build).
bool hasCargoModules(CrossTarget target) =>
    target.modules.any((m) => m.build == ModuleBuild.cargo);
