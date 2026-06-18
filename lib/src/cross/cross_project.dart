import 'dart:io';

import 'package:emb_cli/src/cross/cross_arch.dart';
import 'package:emb_cli/src/manifest/manifest_loader.dart';
import 'package:path/path.dart' as p;

/// Thrown when a project's `.emb/` directory (or a manifest) can't be resolved
/// into a coherent set of cross targets.
class CrossProjectException implements Exception {
  CrossProjectException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// One selectable cross target, resolved from either a dedicated `.emb/` file
/// or a `cross.targets` entry inside a family file.
class CrossTargetRef {
  CrossTargetRef({
    required this.name,
    required this.cross,
    required this.platform,
    this.arch,
    this.family,
    this.sourcePath,
  });

  /// The `--target` value that selects this entry.
  final String name;

  /// A display arch for listings: derived from `cross.triple` when present,
  /// else the manifest's first `supported_archs`. Null when neither is known.
  final String? arch;

  /// The fully merged `cross:` block (base ⊕ family ⊕ variant), with the
  /// `targets` key removed — ready for `CrossTarget.fromMap`.
  final Map<String, dynamic> cross;

  /// The manifest's `platform:` metadata block ({} when absent).
  final Map<String, dynamic> platform;

  /// The grouping label (family file's platform/id) when this target came from
  /// a `cross.targets` entry; null for a flat one-target file.
  final String? family;

  /// The file this target was resolved from, for diagnostics + listings.
  final String? sourcePath;
}

/// A project's resolved cross targets: the union across every `.emb/` file (or
/// the single manifest), plus the shared `cross:` block a native `local` build
/// uses.
class CrossProject {
  CrossProject({
    required this.id,
    required this.targets,
    required this.nativeCross,
    this.defaultTarget,
  });

  /// The project identifier (single manifest's id, or the `.emb/` base's),
  /// used as the fallback `.deb` package name.
  final String id;

  /// Selectable targets, keyed by [CrossTargetRef.name], in declaration order.
  final Map<String, CrossTargetRef> targets;

  /// The `cross:` fields (sans `targets`) a native `local`/`host` build uses —
  /// the `.emb/base.emb.yaml` block in `.emb/` mode, else the single manifest's.
  final Map<String, dynamic> nativeCross;

  /// The target to build when `--target` is omitted: a flat single-file
  /// manifest's sole target. Null when selection is required (`cross.targets`
  /// or a multi-file `.emb/`), where omitting `--target` means the native
  /// `local` build.
  final String? defaultTarget;

  CrossTargetRef? operator [](String name) => targets[name];
}

/// Resolves a project directory, an explicit manifest file, or a bare `.emb/`
/// directory into a [CrossProject].
class CrossProjectResolver {
  const CrossProjectResolver([this._loader = const ManifestLoader()]);

  final ManifestLoader _loader;

  /// The base file searched for inside a `.emb/` directory.
  static const baseFileName = 'base.emb.yaml';

  /// Target names reserved for the built-in native build.
  static const _reserved = {'local', 'host'};

  /// Resolve [input] into a [CrossProject], or null if no manifest is found.
  CrossProject? resolve(String input) {
    final type = FileSystemEntity.typeSync(input);
    if (type == FileSystemEntityType.file) {
      final m = _loader.loadManifestFile(File(input));
      if (m == null) return null;
      return _single(m.raw, fallback: m.id, sourcePath: input);
    }

    final embDir = Directory(p.join(input, '.emb'));
    if (embDir.existsSync()) return _fromEmbDir(embDir);

    // Back-compat: a package directory with an emb.yaml / pubspec(emb:).
    final m = _loader.loadPackageDir(Directory(input));
    if (m == null) return null;
    return _single(m.raw, fallback: m.id, sourcePath: m.sourcePath);
  }

  /// A single manifest (explicit file or back-compat package dir): its
  /// `cross.targets` (or the one flat target).
  CrossProject _single(
    Map<String, dynamic> manifest, {
    required String fallback,
    String? sourcePath,
  }) {
    final cross = _crossOf(manifest);
    final platform = _platformOf(manifest);
    final name = (platform['name'] as String?) ?? fallback;
    final multi = _hasTargets(cross);
    final targets = _expand(
      cross,
      fallbackName: name,
      platform: platform,
      supportedArchs: _supportedArchs(manifest),
      sourcePath: sourcePath,
      family: multi ? name : null,
    );
    return CrossProject(
      id: fallback,
      targets: targets,
      nativeCross: _withoutTargets(cross),
      // A flat file's single target is the default; a cross.targets file
      // requires an explicit --target (else native local).
      defaultTarget: multi ? null : name,
    );
  }

  CrossProject _fromEmbDir(Directory embDir) {
    final baseFile = File(p.join(embDir.path, baseFileName));
    final baseManifest = baseFile.existsSync()
        ? (_loader.loadManifestFile(baseFile)?.raw ?? const {})
        : const <String, dynamic>{};
    final baseCross = _crossOf(baseManifest);

    final files =
        embDir
            .listSync()
            .whereType<File>()
            .where((f) => f.path.endsWith('.emb.yaml'))
            .where((f) => p.basename(f.path) != baseFileName)
            .toList()
          ..sort((a, b) => a.path.compareTo(b.path));

    final out = <String, CrossTargetRef>{};
    for (final file in files) {
      final fm = _loader.loadManifestFile(file)?.raw;
      if (fm == null) continue;
      final merged = deepMerge(baseManifest, fm);
      final cross = _crossOf(merged);
      // A board's backend set is a complete statement, not an addition: when
      // the board declares cross.backends, it replaces the base's rather than
      // unioning with it (a drm-kms board shouldn't inherit a wayland default).
      final boardCross = fm['cross'];
      if (boardCross is Map && boardCross['backends'] is Map) {
        cross['backends'] = boardCross['backends'];
      }
      final platform = _platformOf(merged);
      final fallback =
          (platform['name'] as String?) ??
          (merged['id'] as String?) ??
          p.basename(file.path).split('.').first;
      final refs = _expand(
        cross,
        fallbackName: fallback,
        platform: platform,
        supportedArchs: _supportedArchs(merged),
        sourcePath: file.path,
        // A multi-target file is a family; label its variants with [fallback].
        family: _hasTargets(cross) ? fallback : null,
      );
      for (final entry in refs.entries) {
        final existing = out[entry.key];
        if (existing != null) {
          throw CrossProjectException(
            'Duplicate target "${entry.key}" in '
            '${p.basename(file.path)} and '
            '${p.basename(existing.sourcePath ?? "?")}.',
          );
        }
        out[entry.key] = entry.value;
      }
    }
    return CrossProject(
      id: (baseManifest['id'] as String?) ?? p.basename(embDir.parent.path),
      targets: out,
      nativeCross: _withoutTargets(baseCross),
    );
  }

  /// Expand one (already base-merged) `cross:` block into its target refs: a
  /// `targets` map yields one ref per key (variant shallow-merged over the
  /// shared fields, matching the single-file `cross.targets` behavior),
  /// otherwise the whole block is one ref named [fallbackName].
  Map<String, CrossTargetRef> _expand(
    Map<String, dynamic> cross, {
    required String fallbackName,
    required Map<String, dynamic> platform,
    List<String> supportedArchs = const [],
    String? sourcePath,
    String? family,
  }) {
    final shared = _withoutTargets(cross);
    final targets = cross['targets'];
    if (targets is! Map || targets.isEmpty) {
      _checkName(fallbackName, sourcePath);
      return {
        fallbackName: CrossTargetRef(
          name: fallbackName,
          cross: shared,
          platform: platform,
          arch: _archOf(shared, supportedArchs),
          sourcePath: sourcePath,
        ),
      };
    }
    final out = <String, CrossTargetRef>{};
    for (final entry in targets.entries) {
      final name = entry.key.toString();
      _checkName(name, sourcePath);
      final override = entry.value is Map
          ? Map<String, dynamic>.from(entry.value as Map)
          : const <String, dynamic>{};
      final merged = {...shared, ...override};
      out[name] = CrossTargetRef(
        name: name,
        cross: merged,
        platform: platform,
        arch: _archOf(merged, supportedArchs),
        family: family,
        sourcePath: sourcePath,
      );
    }
    return out;
  }

  /// A display arch: from the cross triple when present, else the first
  /// declared `supported_archs`.
  String? _archOf(Map<String, dynamic> cross, List<String> supportedArchs) {
    final triple = cross['triple'];
    if (triple is String && triple.isNotEmpty) return archOfTriple(triple);
    return supportedArchs.isNotEmpty ? supportedArchs.first : null;
  }

  List<String> _supportedArchs(Map<String, dynamic> manifest) {
    final a = manifest['supported_archs'];
    return a is List ? a.map((e) => e.toString()).toList() : const [];
  }

  void _checkName(String name, String? sourcePath) {
    if (_reserved.contains(name)) {
      throw CrossProjectException(
        'Target "$name" (in ${sourcePath ?? "manifest"}) is reserved for the '
        'built-in native build.',
      );
    }
  }

  Map<String, dynamic> _crossOf(Map<String, dynamic> manifest) {
    final cross = manifest['cross'];
    return cross is Map
        ? Map<String, dynamic>.from(cross)
        : <String, dynamic>{};
  }

  Map<String, dynamic> _platformOf(Map<String, dynamic> manifest) {
    final platform = manifest['platform'];
    return platform is Map
        ? Map<String, dynamic>.from(platform)
        : <String, dynamic>{};
  }

  bool _hasTargets(Map<String, dynamic> cross) {
    final t = cross['targets'];
    return t is Map && t.isNotEmpty;
  }

  Map<String, dynamic> _withoutTargets(Map<String, dynamic> cross) => {
    for (final e in cross.entries)
      if (e.key != 'targets') e.key: e.value,
  };
}

/// Recursively merge [over] onto [base]: nested maps merge key-by-key; lists
/// and scalars in [over] replace those in [base]. Neither input is mutated.
Map<String, dynamic> deepMerge(
  Map<String, dynamic> base,
  Map<String, dynamic> over,
) {
  final out = Map<String, dynamic>.from(base);
  for (final entry in over.entries) {
    final old = out[entry.key];
    final incoming = entry.value;
    if (old is Map && incoming is Map) {
      out[entry.key] = deepMerge(
        Map<String, dynamic>.from(old),
        Map<String, dynamic>.from(incoming),
      );
    } else {
      out[entry.key] = incoming;
    }
  }
  return out;
}
