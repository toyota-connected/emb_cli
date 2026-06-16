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
    final files = dir
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

  /// Load a self-describing manifest from a package directory: prefers
  /// `emb.yaml`, falls back to an `emb:` key in `pubspec.yaml`. Returns null
  /// if neither is present.
  EmbManifest? loadPackageDir(Directory dir) {
    final embYaml = File(p.join(dir.path, 'emb.yaml'));
    if (embYaml.existsSync()) {
      final map = _yamlToMap(loadYaml(embYaml.readAsStringSync()));
      if (map != null) {
        return EmbManifest.fromMap(_withDefaultId(map, dir),
            sourcePath: embYaml.path);
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
        return EmbManifest.fromMap(_withDefaultId(decoded, file.parent,
            fallbackId: p.basenameWithoutExtension(file.path)),
            sourcePath: file.path);
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
      return node.map(
          (k, v) => MapEntry(k.toString(), _convertYaml(v)));
    }
    if (node is YamlList) {
      return node.map(_convertYaml).toList();
    }
    return node;
  }
}
