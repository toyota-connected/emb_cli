/// The `build:` block of an `emb` manifest — everything needed to build the
/// package's Flutter app into a deployable bundle, so `emb build <package>`
/// needs no extra flags.
///
/// ```yaml
/// emb:
///   build:
///     app_path: .            # the Flutter app dir, relative to the manifest
///     archs: [arm64]         # target architectures
///     modes: [release, debug]
///     output: bundles        # optional output dir (relative to workspace)
/// ```
class BuildConfig {
  const BuildConfig({
    this.appPath = '.',
    this.archs = const [],
    this.modes = const ['release'],
    this.output,
  });

  factory BuildConfig.fromMap(Map<dynamic, dynamic> map) {
    return BuildConfig(
      appPath: (map['app_path'] ?? map['appPath'] ?? '.').toString(),
      archs: _stringList(map['archs']),
      modes: _stringList(map['modes'], fallback: const ['release']),
      output: map['output']?.toString(),
    );
  }

  /// The Flutter application directory, relative to the manifest's location.
  final String appPath;

  /// Target architectures to build (empty → the host arch).
  final List<String> archs;

  /// Runtime modes to build (`debug`/`profile`/`release`).
  final List<String> modes;

  /// Optional output directory (relative to the workspace) for the bundles.
  final String? output;

  static List<String> _stringList(
    dynamic v, {
    List<String> fallback = const [],
  }) {
    if (v is List) return v.map((e) => e.toString()).toList();
    return fallback;
  }

  @override
  String toString() =>
      'BuildConfig(app: $appPath, archs: $archs, modes: $modes)';
}
