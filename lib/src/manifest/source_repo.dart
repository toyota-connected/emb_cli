/// A git source repository declared by a manifest's `src` list.
///
/// Ports the per-entry fields consumed by the Python `get_repo` /
/// `get_workspace_repos` helpers (`uri`, `branch`, `rev`, `dest_name`,
/// `pubspec_path`, recurse submodules).
class SourceRepo {
  const SourceRepo({
    required this.uri,
    this.branch,
    this.rev,
    this.destName,
    this.pubspecPath,
    this.recurseSubmodules = false,
    this.patches = const [],
  });

  factory SourceRepo.fromMap(Map<String, dynamic> map) {
    return SourceRepo(
      uri: (map['uri'] ?? map['url'] ?? '') as String,
      branch: map['branch'] as String?,
      rev: (map['rev'] ?? map['ref']) as String?,
      destName: map['dest_name'] as String?,
      pubspecPath: map['pubspec_path'] as String?,
      recurseSubmodules:
          (map['recurse_submodules'] ?? map['submodules'] ?? false) as bool,
      patches: [
        for (final e in (map['patches'] as List<dynamic>? ?? const [])) '$e',
      ],
    );
  }

  /// The git remote URI.
  final String uri;

  /// Branch to check out, if specified.
  final String? branch;

  /// Explicit revision/commit to check out, if specified.
  final String? rev;

  /// Override the destination folder name (defaults to the repo basename).
  final String? destName;

  /// Sub-path within the repo that holds the Flutter `pubspec.yaml`.
  final String? pubspecPath;

  /// Whether to clone with `--recurse-submodules`.
  final bool recurseSubmodules;

  /// Patch files to `git apply` after checking out [rev]/[branch], in order.
  ///
  /// Paths are relative to the manifest that declared them (absolute paths are
  /// taken as-is), so a manifest stays relocatable and does not depend on the
  /// directory `emb` happened to be run from.
  ///
  /// Re-applying is safe: a sync resets an existing checkout to pristine
  /// before re-applying the series, so editing a patch in place takes effect
  /// on the next sync even though [rev] did not change.
  final List<String> patches;

  @override
  String toString() => 'SourceRepo($uri${branch != null ? "#$branch" : ""})';
}
