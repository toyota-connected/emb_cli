import 'dart:convert';
import 'dart:io';

import 'package:emb_cli/src/cross/boards_dir.dart';
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
    this.nativeSourcePath,
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

  /// The manifest file [nativeCross] was read from, so relative paths it
  /// declares (e.g. augment `patches:`) resolve against the manifest for the
  /// native build the same way a board target's do. Null when no backing file
  /// exists (e.g. an `.emb/` dir without a base manifest).
  final String? nativeSourcePath;

  /// The target to build when `--target` is omitted: a flat single-file
  /// manifest's sole target. Null when selection is required (`cross.targets`
  /// or a multi-file `.emb/`), where omitting `--target` means the native
  /// `local` build.
  final String? defaultTarget;

  CrossTargetRef? operator [](String name) => targets[name];

  /// The effective target for [targetArg] (or the project default), with its
  /// raw `cross:` map and whether it is the native `local`/`host` build. When
  /// `--target` is omitted this is [defaultTarget], else the native build.
  /// Returns null only when a *named* target isn't defined, so the caller can
  /// report it.
  ({
    String name,
    bool isNative,
    Map<String, dynamic> cross,
    String? sourcePath,
  })?
  selectTarget(String? targetArg) {
    final name = targetArg ?? defaultTarget ?? 'local';
    if (name == 'local' || name == 'host') {
      // The native block comes from the base manifest (`.emb/base.emb.yaml`, or
      // the single manifest); carry its path so relative augment `patches:`
      // resolve against it, exactly as a board target's do.
      return (
        name: name,
        isNative: true,
        cross: nativeCross,
        sourcePath: nativeSourcePath,
      );
    }
    final ref = this[name];
    if (ref == null) return null;
    return (
      name: name,
      isNative: false,
      cross: ref.cross,
      sourcePath: ref.sourcePath,
    );
  }
}

/// Resolves a project directory, an explicit manifest file, or a bare `.emb/`
/// directory into a [CrossProject].
class CrossProjectResolver {
  /// [environment] is injectable so rung 2/3 resolution is testable without
  /// depending on whatever the developer happens to have installed. Without
  /// it a test machine's real board library would leak into any test that
  /// omits the boards-dir override.
  CrossProjectResolver([
    this._loader = const ManifestLoader(),
    this._boardsDirOverride,
    Map<String, String>? environment,
  ]) : _environment = environment ?? Platform.environment;

  final ManifestLoader _loader;
  final Map<String, String> _environment;

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

  /// Merge an app-owned manifest layer over a project target's resolved
  /// `cross:` block.
  ///
  /// `emb cross <project> --app <dir>` builds the embedder from `<project>`
  /// and the Flutter app from `<dir>`. The project supplies the board profile
  /// every one of its apps shares; this lets one app add what only *it* needs
  /// — a `-dev` package its Dart build hooks link against, say — without every
  /// consumer of that board carrying it.
  ///
  /// [appDir] is read the same way a project is (`.emb/`, `emb.yaml`, or
  /// `pubspec.yaml` with an `emb:` key), so an app layer is written exactly
  /// like the project layer it overlays, including `extends`. The app's target
  /// named [targetName] wins where the two disagree; `dev_packages` accumulate
  /// rather than replace, per [_mergeCross].
  ///
  /// [native] selects the same block the native build reads on the project
  /// side: `local`/`host` are reserved names no manifest may define as a
  /// target, so an app states what its native build needs in the shared
  /// `cross:` block of its base manifest, exactly as the project does.
  ///
  /// Returns [cross] unchanged when [appDir] has no manifest, or none naming
  /// [targetName] — an app with nothing extra to say costs nothing.
  Map<String, dynamic> applyAppLayer({
    required Map<String, dynamic> cross,
    required String appDir,
    required String targetName,
    bool native = false,
  }) {
    final CrossProject? app;
    try {
      app = resolve(appDir);
    } on CrossProjectException {
      // A malformed app manifest must not take down a build whose project
      // manifest is fine; the app layer is additive by design.
      return cross;
    }
    if (app == null) return cross;
    final layer = native ? app.nativeCross : app[targetName]?.cross;
    if (layer == null || layer.isEmpty) return cross;
    return _mergeCross(cross, layer);
  }

  /// The source path of [appDir]'s layer for [targetName], or null when it has
  /// none. Lets a caller resolve the app layer's relative `patches:` against
  /// the manifest that declared them rather than the project's.
  String? appLayerSourcePath({
    required String appDir,
    required String targetName,
    bool native = false,
  }) {
    try {
      final app = resolve(appDir);
      return native ? app?.nativeSourcePath : app?[targetName]?.sourcePath;
    } on CrossProjectException {
      return null;
    }
  }

  /// Resolve the `extends` chain of a single, already intra-file-merged
  /// `cross:` [block] (the shared fields ⊕ one target's override, with no
  /// `targets` key), returning the map ready for `CrossTarget.fromMap`. A
  /// no-op when the block has no `extends`. [sourcePath] is the manifest the
  /// block came from, used to resolve a relative `<dir>#<target>` reference and
  /// the project root.
  ///
  /// Lets callers that enumerate targets themselves (e.g. `emb matrix`) apply
  /// the same board-library / cross-project resolution the full [resolve] does.
  Map<String, dynamic> resolveExtends(
    Map<String, dynamic> block,
    String? sourcePath,
  ) => _applyExtends(block, sourcePath);

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
      nativeSourcePath: sourcePath,
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
      nativeSourcePath: baseFile.existsSync() ? baseFile.path : null,
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
      final merged = _applyExtends(
        _mergeSharedOverride(shared, override),
        sourcePath,
      );
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
  ///   - `<dir>#<target>` — a target in another emb project at `<dir>` (the
  ///                         project layer; e.g. an app extending an
  ///                         ivi-homescreen target). `<dir>` is relative to the
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
      final where = sourcePath ?? 'manifest';
      // An empty registry is a different failure from a misspelled name, and
      // saying "unknown board" for it sends people to audit a manifest that is
      // fine. Name the real cause and where we looked.
      if (registry.isEmpty) {
        throw CrossProjectException(
          'extends: board library not found — no boards are loaded '
          '(in $where).\n'
          'Looked in: ${_boardsTried.join(", ")}.\n'
          'Run `emb boards sync`, or set EMB_BOARDS_DIR to an emb '
          "checkout's boards/.",
        );
      }
      throw CrossProjectException(
        'extends: unknown board "$name" (in $where). '
        'Known boards: ${registry.keys.join(", ")}.',
      );
    }
    return _applyExtends(base, sourcePath, {...seen, name});
  }

  /// The resolved `cross:` of `<dir>#<target>` — a target from another emb
  /// project (its `<dir>`, relative to the extending manifest's project root).
  /// That project's own `extends` chain is applied by [resolve].
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
  /// `sysroot.dev_packages` and `augment` accumulate (union, order-preserving).
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
    if (base['augment'] is List && over['augment'] is List) {
      merged['augment'] = _unionAugment(
        base['augment'] as List,
        over['augment'] as List,
      );
    }
    return merged;
  }

  /// Shallow-merge a target [override] over the [shared] cross fields, but
  /// union `augment` (like [_mergeCross]) so an augment declared once in shared
  /// block (e.g. a `.emb/base.emb.yaml` crash handler) survives a target that
  /// declares its own, instead of the target's list replacing it.
  static Map<String, dynamic> _mergeSharedOverride(
    Map<String, dynamic> shared,
    Map<String, dynamic> override,
  ) {
    final merged = {...shared, ...override};
    if (shared['augment'] is List && override['augment'] is List) {
      merged['augment'] = _unionAugment(
        shared['augment'] as List,
        override['augment'] as List,
      );
    }
    return merged;
  }

  /// Union two `augment` lists (base first, order-preserving), with a derived
  /// entry replacing a base entry that names the same `pkg` and otherwise being
  /// appended. Lets an inherited augment (e.g. a project layer's crash handler)
  /// survive a target that also declares its own, instead of being replaced.
  static List<dynamic> _unionAugment(List<dynamic> base, List<dynamic> over) {
    final out = <dynamic>[...base];
    String? pkgOf(dynamic e) => e is Map ? e['pkg']?.toString() : null;
    for (final e in over) {
      final pkg = pkgOf(e);
      final i = pkg == null ? -1 : out.indexWhere((b) => pkgOf(b) == pkg);
      if (i >= 0) {
        out[i] = e;
      } else {
        out.add(e);
      }
    }
    return out;
  }

  /// Board name -> hardware `cross:` map, loaded once from the board library.
  /// The board names `extends:` can resolve, in load order.
  ///
  /// Loads through the same rungs a real resolution would, so `emb boards
  /// list` reports what `extends:` actually sees rather than what a chosen
  /// directory happens to contain. Read [boardsProvenance] afterwards for
  /// which rung won.
  List<String> boardNames() => _boardRegistry().keys.toList();

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
            out[e.key.toString()] = _mergeSharedOverride(shared, override);
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

  /// Where the board library came from, for `doctor` and error messages.
  /// Null until [_boardsDir] has run.
  String? boardsProvenance;

  /// The paths [_boardsDir] considered, in order, for the not-found message.
  final List<String> _boardsTried = [];

  /// The board-library directory, first hit wins. Rungs are whole-directory
  /// selections and are deliberately **not** merged: a per-file union would let
  /// a stale installed board silently shadow a checkout edit, which is worse
  /// than a clean miss because it is quiet.
  ///
  /// 1. constructor override (tests)
  /// 2. `EMB_BOARDS_DIR` — returned even if absent, so a wrong override fails
  ///    loudly instead of falling through to something that happens to work
  /// 3. the installed data dir — what `bootstrap`/`emb boards sync` writes
  /// 4. the emb_cli package's `boards/` via package_config — `dart run`
  /// 5. a walk up from the running script — `dart run` fallback
  ///
  /// Rungs 4 and 5 stay so an in-checkout run needs no install step. Neither
  /// resolves for an AOT-compiled `emb`, which is why rung 3 exists.
  Directory? _boardsDir() {
    _boardsTried.clear();
    // Every rung consulted is recorded, including the one that wins: a rung can
    // resolve to a directory that exists but holds no boards, and the
    // not-found message has to be able to name it.
    if (_boardsDirOverride != null) {
      _boardsTried.add(_boardsDirOverride.path);
      boardsProvenance = 'constructor override';
      return _boardsDirOverride;
    }

    final env = _environment['EMB_BOARDS_DIR'];
    if (env != null && env.isNotEmpty) {
      _boardsTried.add(
        r'$EMB_BOARDS_DIR='
        '$env',
      );
      boardsProvenance = r'$EMB_BOARDS_DIR';
      return Directory(env);
    }
    _boardsTried.add(r'$EMB_BOARDS_DIR (unset)');

    final installed = resolveBoardsDir(environment: _environment);
    if (installed.existsSync()) {
      _boardsTried.add(installed.path);
      boardsProvenance = 'installed (${installed.path})';
      return installed;
    }
    _boardsTried.add('${installed.path} (absent)');

    final discovered = _discoverBoardsDir();
    if (discovered != null) {
      boardsProvenance = 'package/script relative (${discovered.path})';
      return discovered;
    }
    _boardsTried.add(
      Platform.packageConfig == null
          ? '<package>/boards (n/a: compiled binary)'
          : '<package>/boards (absent)',
    );
    boardsProvenance = 'not found';
    return null;
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
