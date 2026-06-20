import 'dart:convert';
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
  CrossProjectResolver([
    this._loader = const ManifestLoader(),
    this._boardsDirOverride,
  ]);

  final ManifestLoader _loader;

  /// Where emb's shipped board library lives. Null = auto-discover (env
  /// `EMB_BOARDS_DIR`, then the `boards/` dir of the emb_cli package). Tests
  /// point this at a fixture.
  final Directory? _boardsDirOverride;

  /// Lazily-loaded board registry: board name -> its hardware `cross:` map.
  Map<String, Map<String, dynamic>>? _boards;

  /// Project dirs currently being resolved through a cross-project `extends`,
  /// to break `app -> project -> app` reference cycles.
  final Set<String> _resolvingProjects = {};

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
      // merging with it (a drm-kms board shouldn't inherit a wayland default).
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
      final resolved = _applyExtends(shared, sourcePath);
      return {
        fallbackName: CrossTargetRef(
          name: fallbackName,
          cross: resolved,
          platform: platform,
          arch: _archOf(resolved, supportedArchs),
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
      final merged = _applyExtends({...shared, ...override}, sourcePath);
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

  /// Resolve a `cross.extends` reference: deep-merge [cross] (the derived
  /// project/app layer) over the resolved base it names. Two forms:
  ///   - `<board>`        — a target in emb's shipped board library (hardware).
  ///   - `<dir>#<target>` — a target in another emb project at <dir> (the
  ///                         project layer; e.g. an app extending an
  ///                         ivi-homescreen target). <dir> is relative to the
  ///                         extending manifest's project root.
  /// Chains resolve recursively (app -> project -> board). No-op without
  /// `extends`.
  Map<String, dynamic> _applyExtends(
    Map<String, dynamic> cross,
    String? sourcePath, [
    Set<String> seen = const {},
  ]) {
    final ext = cross['extends'];
    if (ext == null) return cross;
    final ref = ext.toString();
    if (seen.contains(ref)) {
      throw CrossProjectException(
        'extends: cycle through "$ref" (in ${sourcePath ?? "manifest"}).',
      );
    }
    final base = ref.contains('#')
        ? _projectExtendsBase(ref, sourcePath)
        : _boardExtendsBase(ref, sourcePath, seen);
    final derived = {...cross}..remove('extends');
    return _mergeCross(base, derived);
  }

  /// The resolved `cross:` of a board named [name] from the shipped board
  /// library, with its own `extends` chain applied.
  Map<String, dynamic> _boardExtendsBase(
    String name,
    String? sourcePath,
    Set<String> seen,
  ) {
    final registry = _boardRegistry();
    final base = registry[name];
    if (base == null) {
      final known = registry.keys.isEmpty ? 'none' : registry.keys.join(', ');
      throw CrossProjectException(
        'extends: unknown board "$name" (in ${sourcePath ?? "manifest"}). '
        'Known boards: $known.',
      );
    }
    return _applyExtends(base, sourcePath, {...seen, name});
  }

  /// The resolved `cross:` of `<dir>#<target>` — a target from another emb
  /// project at <dir> (relative to the extending manifest's project root). That
  /// project's own `extends` chain is applied by [resolve].
  Map<String, dynamic> _projectExtendsBase(String ref, String? sourcePath) {
    final i = ref.lastIndexOf('#');
    final dirRef = ref.substring(0, i);
    final name = ref.substring(i + 1);
    final root = _projectRootOf(sourcePath);
    final dir = p.normalize(p.join(root, dirRef));
    final abs = p.absolute(dir);
    if (!_resolvingProjects.add(abs)) {
      throw CrossProjectException(
        'extends: project reference cycle at "$dir".',
      );
    }
    try {
      final project = resolve(dir);
      if (project == null) {
        throw CrossProjectException(
          'extends: no emb project at "$dir" (from "$ref").',
        );
      }
      final target = project.targets[name];
      if (target == null) {
        throw CrossProjectException(
          'extends: project "$dir" has no target "$name" (from "$ref"). '
          'Available: ${project.targets.keys.join(", ")}.',
        );
      }
      return target.cross;
    } finally {
      _resolvingProjects.remove(abs);
    }
  }

  /// The project root for a manifest at [sourcePath]: the `.emb/` parent in
  /// `.emb/` mode, else the manifest file's own directory. Cross-project
  /// `extends` paths are resolved relative to this.
  String _projectRootOf(String? sourcePath) {
    if (sourcePath == null) return '.';
    final dir = p.dirname(sourcePath);
    return p.basename(dir) == '.emb' ? p.dirname(dir) : dir;
  }

  /// Merge the [over] (derived) layer onto [base], with the cross-layer rules:
  /// nested maps deep-merge; `backends` is a complete statement (replace);
  /// `sysroot.dev_packages` accumulate (union, order-preserving).
  Map<String, dynamic> _mergeCross(
    Map<String, dynamic> base,
    Map<String, dynamic> over,
  ) {
    final merged = deepMerge(base, over);
    if (over['backends'] is Map) merged['backends'] = over['backends'];
    final baseSys = base['sysroot'];
    final overSys = over['sysroot'];
    if (baseSys is Map &&
        overSys is Map &&
        baseSys['dev_packages'] is List &&
        overSys['dev_packages'] is List) {
      final union = <String>[
        for (final e in baseSys['dev_packages'] as List) e.toString(),
      ];
      for (final e in overSys['dev_packages'] as List) {
        if (!union.contains(e.toString())) union.add(e.toString());
      }
      (merged['sysroot'] as Map)['dev_packages'] = union;
    }
    return merged;
  }

  /// Board name -> hardware `cross:` map, loaded once from the board library.
  Map<String, Map<String, dynamic>> _boardRegistry() {
    if (_boards case final cached?) return cached;
    final out = <String, Map<String, dynamic>>{};
    final dir = _boardsDir();
    if (dir != null && dir.existsSync()) {
      for (final f in dir.listSync().whereType<File>().where(
        (f) => f.path.endsWith('.emb.yaml'),
      )) {
        final m = _loader.loadManifestFile(f)?.raw;
        if (m == null) continue;
        final cross = _crossOf(m);
        final shared = _withoutTargets(cross);
        final targets = cross['targets'];
        if (targets is Map && targets.isNotEmpty) {
          for (final e in targets.entries) {
            final override = e.value is Map
                ? Map<String, dynamic>.from(e.value as Map)
                : const <String, dynamic>{};
            out[e.key.toString()] = {...shared, ...override};
          }
        } else {
          final name =
              (m['id'] as String?) ?? p.basename(f.path).split('.').first;
          out[name] = shared;
        }
      }
    }
    return _boards = out;
  }

  /// The board-library directory: an explicit override, then `EMB_BOARDS_DIR`,
  /// then the `boards/` dir of the emb_cli package (via its package_config),
  /// then a walk up from the running script.
  Directory? _boardsDir() {
    if (_boardsDirOverride != null) return _boardsDirOverride;
    final env = Platform.environment['EMB_BOARDS_DIR'];
    if (env != null && env.isNotEmpty) return Directory(env);
    return _discoverBoardsDir();
  }

  Directory? _discoverBoardsDir() {
    final pc = Platform.packageConfig;
    if (pc != null) {
      try {
        final pcUri = pc.startsWith('file:') ? Uri.parse(pc) : Uri.file(pc);
        final pcFile = File.fromUri(pcUri);
        if (pcFile.existsSync()) {
          final json =
              jsonDecode(pcFile.readAsStringSync()) as Map<String, dynamic>;
          for (final pkg in (json['packages'] as List? ?? const [])) {
            if (pkg is Map && pkg['name'] == 'emb_cli') {
              var root = (pkg['rootUri'] ?? '').toString();
              if (!root.endsWith('/')) root = '$root/';
              final dir = Directory.fromUri(
                pcUri.resolve(root).resolve('boards/'),
              );
              if (dir.existsSync()) return dir;
            }
          }
        }
      } on Object {
        // fall through to the script-relative walk
      }
    }
    var dir = File.fromUri(Platform.script).parent;
    for (var i = 0; i < 6; i++) {
      final boards = Directory(p.join(dir.path, 'boards'));
      if (boards.existsSync()) return boards;
      dir = dir.parent;
    }
    return null;
  }
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
