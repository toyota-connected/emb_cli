import 'package:emb_cli/src/manifest/build_config.dart';
import 'package:emb_cli/src/manifest/host_deps.dart';
import 'package:emb_cli/src/manifest/source_repo.dart';

/// A normalized build/dependency manifest for a single component.
///
/// Unifies two on-disk forms:
///  * the new self-describing `emb` manifest (`emb.yaml`, or an `emb:` key in
///    a package's `pubspec.yaml`), which declares host deps as structured
///    package-name lists; and
///  * the legacy central `configs/*.json` schema, whose host deps live as
///    inline `sudo … install` strings under
///    `runtime.pre-requisites[arch][distro][version].cmds`.
class EmbManifest {
  const EmbManifest({
    required this.id,
    required this.type,
    required this.load,
    required this.supportedArchs,
    required this.supportedHostTypes,
    required this.env,
    required this.src,
    required this.deps,
    this.build,
    this.flutterVersion,
    this.sourcePath,
    this.raw = const {},
  });

  /// Parse a manifest map. Detects structured vs legacy host-dep schemas
  /// automatically, so both `emb` manifests and legacy `configs/*.json`
  /// documents flow through one path.
  factory EmbManifest.fromMap(
    Map<String, dynamic> map, {
    String? sourcePath,
  }) {
    final deps = _parseDeps(map);
    final srcList = (map['src'] ?? map['repos']) as List<dynamic>? ?? const [];

    return EmbManifest(
      id: (map['id'] ?? '') as String,
      type: (map['type'] ?? 'app') as String,
      load: (map['load'] ?? true) as bool,
      supportedArchs:
          _stringList(map['supported_archs'] ?? map['supportedArchs']),
      supportedHostTypes: _stringList(
          map['supported_host_types'] ?? map['supportedHostTypes']),
      env: _stringMap(map['env']),
      src: srcList
          .whereType<Map<dynamic, dynamic>>()
          .map((e) => SourceRepo.fromMap(Map<String, dynamic>.from(e)))
          .toList(),
      deps: deps,
      build: map['build'] is Map
          ? BuildConfig.fromMap(map['build'] as Map<dynamic, dynamic>)
          : null,
      flutterVersion: map['flutter_version'] as String?,
      sourcePath: sourcePath,
      raw: map,
    );
  }

  /// Component identifier.
  final String id;

  /// Component kind (`app`, `dependency`, `toolchain`, …).
  final String type;

  /// Whether this component participates in a default workspace load.
  final bool load;

  /// Architectures this component supports (`supported_archs`).
  final List<String> supportedArchs;

  /// Host types this component supports (`supported_host_types`): distro ids
  /// on Linux, else `darwin`/`windows`.
  final List<String> supportedHostTypes;

  /// Environment variable declarations (raw, unexpanded).
  final Map<String, String> env;

  /// Git source repositories.
  final List<SourceRepo> src;

  /// Host OS package dependencies.
  final HostDeps deps;

  /// Build configuration (`build:`), when this package is buildable.
  final BuildConfig? build;

  /// Pinned Flutter version, when declared.
  final String? flutterVersion;

  /// Path the manifest was loaded from, for diagnostics.
  final String? sourcePath;

  /// The raw parsed map, retained for later build phases (post_cmds,
  /// gclient_config, qemu/docker/remote platform blocks).
  final Map<String, dynamic> raw;

  static HostDeps _parseDeps(Map<String, dynamic> map) {
    // New structured schema takes precedence when present.
    final structured = map['deps'];
    if (structured is Map) {
      return HostDeps.fromStructured(structured);
    }
    // Legacy: runtime.pre-requisites.
    final runtime = map['runtime'];
    if (runtime is Map) {
      final prereq = runtime['pre-requisites'];
      if (prereq is Map) {
        return HostDeps.fromLegacyPreRequisites(prereq);
      }
    }
    return HostDeps.empty;
  }

  static List<String> _stringList(dynamic value) {
    if (value is List) return value.map((e) => e.toString()).toList();
    return const [];
  }

  static Map<String, String> _stringMap(dynamic value) {
    if (value is Map) {
      return value.map((k, v) => MapEntry(k.toString(), v.toString()));
    }
    return const {};
  }

  @override
  String toString() => 'EmbManifest($id, type: $type, '
      'deps: ${deps.rules.length} rules)';
}
