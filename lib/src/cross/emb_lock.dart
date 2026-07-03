import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

/// The kind of artifact a [LockedArtifact] pins.
enum ArtifactKind {
  /// A downloaded cross toolchain tarball (arm-gnu).
  toolchain,

  /// A `populate_sdk` self-extracting installer (yocto-sdk).
  sdk,

  /// A distro image the sysroot is unpacked from (arm-gnu, image-sourced).
  image,

  /// A source tarball built into the overlay (augment libs).
  augment,

  /// A live device the sysroot was rsync'd from — provenance only, no sha
  /// (a running host can't be content-pinned).
  device;

  String get token => name;

  static ArtifactKind fromToken(String token) => ArtifactKind.values.firstWhere(
    (k) => k.name == token,
    orElse: () => throw ArgumentError('unknown artifact kind: $token'),
  );
}

/// One pinned input to a target's resolution: a URL and the sha256 of the bytes
/// that were actually fetched (or, for [ArtifactKind.device], just the host).
class LockedArtifact {
  const LockedArtifact({required this.kind, this.url, this.sha256, this.host});

  factory LockedArtifact.fromMap(Map<dynamic, dynamic> map) => LockedArtifact(
    kind: ArtifactKind.fromToken((map['kind'] ?? '').toString()),
    url: map['url']?.toString(),
    sha256: map['sha256']?.toString(),
    host: map['host']?.toString(),
  );

  final ArtifactKind kind;
  final String? url;
  final String? sha256;
  final String? host;

  /// A stable identity for ordering/matching: same kind + url is the same
  /// artifact across resolutions.
  String get id => '${kind.token}:${url ?? host ?? ''}';

  Map<String, String> toMap() => {
    'kind': kind.token,
    if (url != null) 'url': url!,
    if (sha256 != null) 'sha256': sha256!,
    if (host != null) 'host': host!,
  };
}

/// One `-dev` package as resolved into a sysroot: the exact version and the
/// digest the apt index advertised. A `Packages.lock` in miniature — recorded
/// so a re-resolve that a live (or substituted) mirror answers with a different
/// version fails loudly instead of building against silently-changed headers.
class LockedPackage {
  const LockedPackage({required this.name, this.version, this.sha256});

  factory LockedPackage.fromMap(Map<dynamic, dynamic> map) => LockedPackage(
    name: (map['name'] ?? '').toString(),
    version: map['version']?.toString(),
    sha256: map['sha256']?.toString(),
  );

  final String name;
  final String? version;
  final String? sha256;

  Map<String, String> toMap() => {
    'name': name,
    if (version != null) 'version': version!,
    if (sha256 != null) 'sha256': sha256!,
  };
}

/// The resolved facts for a single target, as captured at resolve time.
///
/// Distinct from the manifest's *declared* inputs: it records what resolution
/// actually produced — the chosen toolchain version (which under
/// `deriveFromSysroot` is computed, not declared), the codename it was derived
/// from, the content fingerprints, and each fetched artifact's sha256.
class LockedTarget {
  const LockedTarget({
    required this.provider,
    required this.triple,
    required this.sysrootKey,
    required this.buildKey,
    this.toolchainVersion,
    this.compilerVersion,
    this.codename,
    this.artifacts = const [],
    this.packages = const [],
  });

  factory LockedTarget.fromMap(Map<dynamic, dynamic> map) => LockedTarget(
    provider: (map['provider'] ?? '').toString(),
    triple: (map['triple'] ?? '').toString(),
    sysrootKey: (map['sysroot_key'] ?? '').toString(),
    buildKey: (map['build_key'] ?? '').toString(),
    toolchainVersion: map['toolchain_version']?.toString(),
    compilerVersion: map['compiler_version']?.toString(),
    codename: map['codename']?.toString(),
    artifacts: (map['artifacts'] as List<dynamic>? ?? const [])
        .whereType<Map<dynamic, dynamic>>()
        .map(LockedArtifact.fromMap)
        .toList(),
    packages: (map['packages'] as List<dynamic>? ?? const [])
        .whereType<Map<dynamic, dynamic>>()
        .map(LockedPackage.fromMap)
        .toList(),
  );

  final String provider;
  final String triple;
  final String sysrootKey;
  final String buildKey;
  final String? toolchainVersion;

  /// The cross compiler version (e.g. gcc `-dumpfullversion`), when probed.
  /// Distinguishes toolchains that share a recipe/SDK version string but ship
  /// a different gcc (e.g. two Yocto releases building the same recipe PV).
  final String? compilerVersion;
  final String? codename;
  final List<LockedArtifact> artifacts;

  /// The `-dev` packages resolved into the sysroot, with their pinned versions.
  final List<LockedPackage> packages;

  /// Artifacts in a stable order (kind, then url) for deterministic output.
  List<LockedArtifact> get sortedArtifacts => [...artifacts]
    ..sort((a, b) {
      final k = a.kind.index.compareTo(b.kind.index);
      return k != 0 ? k : a.id.compareTo(b.id);
    });

  /// Packages in a stable order (by name) for deterministic output.
  List<LockedPackage> get sortedPackages =>
      [...packages]..sort((a, b) => a.name.compareTo(b.name));

  /// Drift of this locked target against a freshly-[resolved] one — the human
  /// reasons the resolution no longer matches the lock. Empty means they agree.
  ///
  /// An artifact whose sha is unknown on one side (e.g. a cached image whose
  /// `.xz` was pruned, so this run couldn't re-hash it) is skipped rather than
  /// reported, so verification only fires on artifacts both sides observed.
  List<String> driftAgainst(LockedTarget resolved) {
    final problems = <String>[];
    if (resolved.provider != provider) {
      problems.add('provider: locked $provider, resolved ${resolved.provider}');
    }
    if (resolved.triple != triple) {
      problems.add('triple: locked $triple, resolved ${resolved.triple}');
    }
    if (resolved.toolchainVersion != toolchainVersion) {
      problems.add(
        'toolchain_version: locked $toolchainVersion, '
        'resolved ${resolved.toolchainVersion}',
      );
    }
    if (resolved.compilerVersion != compilerVersion) {
      problems.add(
        'compiler_version: locked $compilerVersion, '
        'resolved ${resolved.compilerVersion}',
      );
    }
    if (resolved.sysrootKey != sysrootKey || resolved.buildKey != buildKey) {
      problems.add(
        'inputs changed (manifest edited): re-run with --update-lock',
      );
    }
    final resolvedById = {for (final a in resolved.artifacts) a.id: a};
    for (final locked in artifacts) {
      final now = resolvedById[locked.id];
      if (now == null) continue; // not re-materialized this run
      if (locked.sha256 != null &&
          now.sha256 != null &&
          locked.sha256 != now.sha256) {
        problems.add(
          '${locked.kind.token} sha256 mismatch for ${locked.url}: '
          'locked ${locked.sha256}, resolved ${now.sha256} '
          '(URL may have moved; --update-lock if intentional)',
        );
      }
    }

    // Package drift: a mirror answering an -dev name with a different version
    // than was locked means the sysroot's headers/libs changed underfoot.
    final resolvedPkgs = {for (final p in resolved.packages) p.name: p};
    for (final locked in packages) {
      final now = resolvedPkgs[locked.name];
      if (now == null || locked.version == null || now.version == null) {
        continue; // not re-resolved this run, or a side lacks a version
      }
      if (locked.version != now.version) {
        problems.add(
          'package ${locked.name}: locked ${locked.version}, '
          'resolved ${now.version} '
          '(mirror moved; --update-lock if intentional)',
        );
      }
    }
    return problems;
  }

  Map<String, dynamic> toMap() => {
    'provider': provider,
    'triple': triple,
    if (toolchainVersion != null) 'toolchain_version': toolchainVersion,
    if (compilerVersion != null) 'compiler_version': compilerVersion,
    if (codename != null) 'codename': codename,
    'sysroot_key': sysrootKey,
    'build_key': buildKey,
    if (artifacts.isNotEmpty)
      'artifacts': [for (final a in sortedArtifacts) a.toMap()],
    if (packages.isNotEmpty)
      'packages': [for (final p in sortedPackages) p.toMap()],
  };
}

/// The tool versions a resolve ran with, pinned at the document root. Distinct
/// from the per-target facts: these are the host-side inputs (emb itself, the
/// Flutter/engine commits, rustc) that shape every target's output, and whose
/// drift explains an otherwise-mysterious rebuild difference in year nine.
class LockEnv {
  const LockEnv({
    this.embVersion,
    this.engineCommit,
    this.flutterCommit,
    this.rustcVersion,
  });

  factory LockEnv.fromMap(Map<dynamic, dynamic> map) => LockEnv(
    embVersion: map['emb_version']?.toString(),
    engineCommit: map['engine_commit']?.toString(),
    flutterCommit: map['flutter_commit']?.toString(),
    rustcVersion: map['rustc_version']?.toString(),
  );

  final String? embVersion;
  final String? engineCommit;
  final String? flutterCommit;
  final String? rustcVersion;

  bool get isEmpty =>
      embVersion == null &&
      engineCommit == null &&
      flutterCommit == null &&
      rustcVersion == null;
}

/// An `emb.lock` document: resolved facts per target, so a moved URL or a
/// drifted derived-version fails loudly instead of silently building something
/// different. YAML, pinned to a schema [version], keyed by target name, with an
/// [env] block of the host tool versions the resolve ran with.
class EmbLock {
  EmbLock({
    this.version = currentVersion,
    this.env = const LockEnv(),
    Map<String, LockedTarget>? targets,
  }) : targets = targets ?? {};

  /// Parse a lock document. Throws [FormatException] on a non-map root.
  factory EmbLock.parse(String yaml) {
    final doc = loadYaml(yaml);
    if (doc is! YamlMap) {
      throw const FormatException('emb.lock: root is not a mapping');
    }
    final targets = <String, LockedTarget>{};
    final raw = doc['targets'];
    if (raw is YamlMap) {
      for (final entry in raw.entries) {
        final value = entry.value;
        if (value is YamlMap) {
          targets[entry.key.toString()] = LockedTarget.fromMap(value);
        }
      }
    }
    final env = doc['env'];
    return EmbLock(
      version:
          int.tryParse('${doc['version'] ?? currentVersion}') ?? currentVersion,
      env: env is YamlMap ? LockEnv.fromMap(env) : const LockEnv(),
      targets: targets,
    );
  }

  /// Current lock schema version.
  static const currentVersion = 1;

  final int version;
  final LockEnv env;
  final Map<String, LockedTarget> targets;

  /// Load the lock at [file], or null when it is absent. Throws
  /// [FormatException] on a malformed document (the caller surfaces it).
  static EmbLock? load(File file) =>
      file.existsSync() ? EmbLock.parse(file.readAsStringSync()) : null;

  /// A copy with [target] set/replaced under [name].
  EmbLock withTarget(String name, LockedTarget target) =>
      EmbLock(version: version, env: env, targets: {...targets, name: target});

  /// A copy with the root [env] self-pins replaced.
  EmbLock withEnv(LockEnv env) =>
      EmbLock(version: version, env: env, targets: targets);

  void save(File file) {
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(encode());
  }

  /// Serialize to deterministic YAML (targets and artifacts sorted), so a
  /// re-resolve that changes nothing produces a byte-identical file.
  String encode() {
    final out = StringBuffer()
      ..writeln('# Generated by `emb cross`. Do not edit by hand.')
      ..writeln('# Pins resolved toolchain/sysroot inputs per target.')
      ..writeln('version: $version');
    if (!env.isEmpty) {
      out.writeln('env:');
      void field(String key, String? value) {
        if (value != null) out.writeln('  $key: ${_scalar(value)}');
      }

      field('emb_version', env.embVersion);
      field('engine_commit', env.engineCommit);
      field('flutter_commit', env.flutterCommit);
      field('rustc_version', env.rustcVersion);
    }
    if (targets.isEmpty) {
      out.writeln('targets: {}');
      return out.toString();
    }
    out.writeln('targets:');
    final names = targets.keys.toList()..sort();
    for (final name in names) {
      out.writeln('  ${_scalar(name)}:');
      _writeTarget(out, targets[name]!);
    }
    return out.toString();
  }

  void _writeTarget(StringBuffer out, LockedTarget t) {
    void field(String key, String? value) {
      if (value != null) {
        out.writeln('    $key: ${_scalar(value)}');
      }
    }

    field('provider', t.provider);
    field('triple', t.triple);
    field('toolchain_version', t.toolchainVersion);
    field('compiler_version', t.compilerVersion);
    field('codename', t.codename);
    field('sysroot_key', t.sysrootKey);
    field('build_key', t.buildKey);
    if (t.artifacts.isNotEmpty) {
      out.writeln('    artifacts:');
      for (final a in t.sortedArtifacts) {
        out.writeln('      - kind: ${_scalar(a.kind.token)}');
        if (a.url != null) {
          out.writeln('        url: ${_scalar(a.url!)}');
        }
        if (a.sha256 != null) {
          out.writeln('        sha256: ${_scalar(a.sha256!)}');
        }
        if (a.host != null) {
          out.writeln('        host: ${_scalar(a.host!)}');
        }
      }
    }
    if (t.packages.isNotEmpty) {
      out.writeln('    packages:');
      for (final pkg in t.sortedPackages) {
        out.writeln('      - name: ${_scalar(pkg.name)}');
        if (pkg.version != null) {
          out.writeln('        version: ${_scalar(pkg.version!)}');
        }
        if (pkg.sha256 != null) {
          out.writeln('        sha256: ${_scalar(pkg.sha256!)}');
        }
      }
    }
  }

  /// Single-quote a scalar so URLs/colons/leading-indicator chars never break
  /// the document. Embedded single quotes are doubled per the YAML spec.
  static String _scalar(String value) => "'${value.replaceAll("'", "''")}'";
}

/// What [reconcileLock] decided to do with a target's lock entry.
enum LockAction {
  /// The lock was (re)written — first resolve, or `--update-lock`. The new
  /// document is in [LockReconcile.lock].
  wrote,

  /// The resolution matched the lock (or verification was skipped).
  verified,

  /// The resolution drifted from the lock; [LockReconcile.problems] says how.
  drifted,
}

/// Outcome of [reconcileLock].
class LockReconcile {
  const LockReconcile(this.action, {this.lock, this.problems = const []});

  final LockAction action;

  /// The document to persist — non-null only for [LockAction.wrote].
  final EmbLock? lock;

  /// Human drift reasons — non-empty only for [LockAction.drifted].
  final List<String> problems;
}

/// The `emb.lock` entry key for a resolve of [target] from [inputPath].
///
/// A flat manifest **file** qualifies the target with the manifest stem
/// (`<stem>:<target>`) so two co-located `*.emb.yaml` in one directory — which
/// share a single `<dir>/emb.lock` — don't clobber each other's entry when they
/// resolve the same target name. A project **directory** ([isDirectory]) uses
/// the bare [target]: its target names are already project-unique.
String lockKey({
  required String inputPath,
  required bool isDirectory,
  required String target,
}) {
  if (isDirectory) return target;
  final stem = p.basename(inputPath).split('.').first;
  return '$stem:$target';
}

/// Pure reconciliation of a freshly [resolved] target against the [existing]
/// lock (no IO): auto-create the entry when absent or [updateLock] rewrite it
/// (→ [LockAction.wrote] with the document to save), else verify and report
/// drift ([LockAction.drifted]) — unless [verify] is false (→
/// [LockAction.verified]).
LockReconcile reconcileLock({
  required EmbLock? existing,
  required String target,
  required LockedTarget resolved,
  required bool updateLock,
  required bool verify,
}) {
  final locked = existing?.targets[target];
  if (updateLock || locked == null) {
    return LockReconcile(
      LockAction.wrote,
      lock: (existing ?? EmbLock()).withTarget(target, resolved),
    );
  }
  if (!verify) return const LockReconcile(LockAction.verified);
  final problems = locked.driftAgainst(resolved);
  return problems.isEmpty
      ? const LockReconcile(LockAction.verified)
      : LockReconcile(LockAction.drifted, problems: problems);
}
