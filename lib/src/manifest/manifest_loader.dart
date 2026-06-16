import 'dart:convert';
import 'dart:io';

import 'package:emb_cli/src/manifest/emb_manifest.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

/// Loads [EmbManifest]s from disk.
///
/// Two sources are supported:
///  * a directory of legacy `configs/*.json` documents
///    ([loadConfigDir]); and
///  * self-describing packages exposing an `emb.yaml` or an `emb:` key in
///    their `pubspec.yaml` ([loadPackageDir] / [discoverPackages]).
class ManifestLoader {
  const ManifestLoader();

  /// Load every `*.json` config in [dir] (non-recursive), sorted by name.
  /// Skips `globals.json` (workspace globals, not a component).
  List<EmbManifest> loadConfigDir(Directory dir) {
    if (!dir.existsSync()) return const [];
    final files =
        dir
            .listSync()
            .whereType<File>()
            .where((f) => f.path.endsWith('.json'))
            .where((f) => p.basename(f.path) != 'globals.json')
            .toList()
          ..sort((a, b) => a.path.compareTo(b.path));
    final out = <EmbManifest>[];
    for (final f in files) {
      final manifest = _tryLoadJson(f);
      if (manifest != null) out.add(manifest);
    }
    return out;
  }

  /// Load a single legacy JSON config file.
  EmbManifest? loadConfigFile(File file) => _tryLoadJson(file);

  /// Select the manifests that should apply, honoring each manifest's `load`
  /// flag and explicit [enable]/[disable] overrides matched by
  /// [EmbManifest.id].
  ///
  /// A manifest applies when its id is in [enable], or its `load` is true and
  /// its id is not in [disable]. So `--enable` forces a `load: false` component
  /// on, `--disable` forces a `load: true` one off, and `enable` wins if an id
  /// is in both. Ids in [enable]/[disable] that match no manifest are ignored.
  /// The occurrence order of [manifests] is preserved.
  List<EmbManifest> select(
    List<EmbManifest> manifests, {
    Set<String> enable = const {},
    Set<String> disable = const {},
  }) => [
    for (final m in manifests)
      if (enable.contains(m.id) || (m.load && !disable.contains(m.id))) m,
  ];

  /// Load a self-describing manifest from an explicit YAML [file] (e.g. an
  /// `examples/cross/pi5.emb.yaml`). The id defaults to the file's base name
  /// (sans extensions). Returns null if the file is absent or not a map.
  EmbManifest? loadManifestFile(File file) {
    if (!file.existsSync()) return null;
    final map = _yamlToMap(loadYaml(file.readAsStringSync()));
    if (map == null) return null;
    return EmbManifest.fromMap(
      _withDefaultId(
        map,
        file.parent,
        fallbackId: p.basename(file.path).split('.').first,
      ),
      sourcePath: file.path,
    );
  }

  /// Load a self-describing manifest from a package directory: prefers
  /// `emb.yaml`, falls back to an `emb:` key in `pubspec.yaml`. Returns null
  /// if neither is present.
  EmbManifest? loadPackageDir(Directory dir) {
    final embYaml = File(p.join(dir.path, 'emb.yaml'));
    if (embYaml.existsSync()) {
      final map = _yamlToMap(loadYaml(embYaml.readAsStringSync()));
      if (map != null) {
        return EmbManifest.fromMap(
          _withDefaultId(map, dir),
          sourcePath: embYaml.path,
        );
      }
    }
    final pubspec = File(p.join(dir.path, 'pubspec.yaml'));
    if (pubspec.existsSync()) {
      final doc = _yamlToMap(loadYaml(pubspec.readAsStringSync()));
      final emb = doc?['emb'];
      if (emb is Map) {
        final map = _withDefaultId(
          Map<String, dynamic>.from(emb),
          dir,
          fallbackId: doc?['name']?.toString(),
        );
        return EmbManifest.fromMap(map, sourcePath: pubspec.path);
      }
    }
    return null;
  }

  /// Discover self-describing manifests in immediate subdirectories of [root]
  /// (e.g. a workspace `app/` folder).
  List<EmbManifest> discoverPackages(Directory root) {
    if (!root.existsSync()) return const [];
    final out = <EmbManifest>[];
    for (final entity in root.listSync().whereType<Directory>()) {
      final manifest = loadPackageDir(entity);
      if (manifest != null) out.add(manifest);
    }
    return out;
  }

  EmbManifest? _tryLoadJson(File file) {
    try {
      final decoded = jsonDecode(file.readAsStringSync());
      if (decoded is Map<String, dynamic>) {
        return EmbManifest.fromMap(
          _withDefaultId(
            decoded,
            file.parent,
            fallbackId: p.basenameWithoutExtension(file.path),
          ),
          sourcePath: file.path,
        );
      }
    } on FormatException {
      // Skip malformed config files rather than aborting the whole load.
    }
    return null;
  }

  Map<String, dynamic> _withDefaultId(
    Map<String, dynamic> map,
    Directory dir, {
    String? fallbackId,
  }) {
    if ((map['id'] ?? '').toString().isNotEmpty) return map;
    return {...map, 'id': fallbackId ?? p.basename(dir.path)};
  }

  /// Recursively convert a parsed YAML node into plain Dart collections.
  Map<String, dynamic>? _yamlToMap(dynamic node) {
    final converted = _convertYaml(node);
    return converted is Map<String, dynamic> ? converted : null;
  }

  dynamic _convertYaml(dynamic node) {
    if (node is YamlMap) {
      return node.map((k, v) => MapEntry(k.toString(), _convertYaml(v)));
    }
    if (node is YamlList) {
      return node.map(_convertYaml).toList();
    }
    return node;
  }
}
