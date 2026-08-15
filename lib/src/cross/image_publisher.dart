/// Pure planner for `emb cross --publish`: builds the container-CLI invocations
/// (existence probe, build, push) for a toolchain image, with no I/O so the
/// argv is unit-testable. The command handler runs the returned [ContainerCmd]s
/// through its injected process runner.
///
/// Registry-agnostic by construction: the image reference is a free-form
/// `host[/path]/name` prefix, authentication is left to a prior
/// `<tool> login`, and the existence check is a plain Registry-v2
/// `manifest inspect` — not any registry's REST API. The same plan therefore
/// serves GHCR, JFrog Artifactory, ECR, Google AR, and Docker Hub alike.
library;

/// A single container-CLI invocation: [exe] plus its [args].
class ContainerCmd {
  const ContainerCmd(this.exe, this.args);

  final String exe;
  final List<String> args;

  @override
  String toString() => '$exe ${args.join(' ')}';
}

/// Builds the publish commands for one toolchain image.
class ImagePublishPlan {
  ImagePublishPlan({
    required this.tool,
    required this.contextDir,
    required this.imagePrefix,
    required this.tags,
    this.push = true,
  }) : assert(tags.isNotEmpty, 'at least one tag is required');

  /// Container CLI to invoke (`docker`, `podman`, …).
  final String tool;

  /// Build context — the platform dir holding `Dockerfile`, `toolchain/`,
  /// `sysroot/`.
  final String contextDir;

  /// Image reference base: `host[/path]/name` (the tag is appended).
  final String imagePrefix;

  /// Tags to apply/push. The first is the primary (the content-addressed
  /// `sysroot_key`) and is the one probed for existence.
  final List<String> tags;

  /// Whether to push after building (false for `--no-push`).
  final bool push;

  /// Fully-qualified references, one per tag.
  List<String> refs() => [for (final t in tags) '$imagePrefix:$t'];

  /// The primary reference (first tag) — the existence-probe / consume target.
  String get primaryRef => refs().first;

  /// The registry-neutral "already published?" probe (exit 0 == exists).
  ///
  /// Prefers `skopeo inspect docker://<ref>` when available: it queries any
  /// Registry-v2 endpoint for single- or multi-arch images and works under both
  /// podman and docker. Without skopeo it falls back to
  /// `<tool> manifest inspect`, which works on real docker; under podman that
  /// fall-back fails (podman rejects single images as manifest lists), so the
  /// caller simply rebuilds — always safe, since the image is
  /// content-addressed.
  ContainerCmd existsProbe({required bool skopeoAvailable}) => skopeoAvailable
      ? ContainerCmd('skopeo', ['inspect', 'docker://$primaryRef'])
      : ContainerCmd(tool, ['manifest', 'inspect', primaryRef]);

  /// Prints just the digest of [ref], for comparing two tags.
  ///
  /// Existence is not enough to decide a publish can be skipped. The primary
  /// tag is content-addressed and so answers "has this content been
  /// published"; any other tag is mutable and answers only "does this name
  /// exist". A mutable tag left pointing at an older image exists, matches no
  /// probe, and quietly serves stale content to everything that consumes it by
  /// name -- which is what the skip has to rule out.
  ContainerCmd digestProbe(String ref, {required bool skopeoAvailable}) =>
      skopeoAvailable
      ? ContainerCmd('skopeo', [
          'inspect',
          '--format',
          '{{.Digest}}',
          'docker://$ref',
        ])
      : ContainerCmd(tool, ['manifest', 'inspect', '--verbose', ref]);

  /// `<tool> build -t <ref> [-t <ref> …] <contextDir>`.
  ContainerCmd build() => ContainerCmd(tool, [
    'build',
    for (final r in refs()) ...['-t', r],
    contextDir,
  ]);

  /// One `<tool> push <ref>` per tag (empty when [push] is false).
  List<ContainerCmd> pushes() => push
      ? [
          for (final r in refs()) ContainerCmd(tool, ['push', r]),
        ]
      : const [];
}
