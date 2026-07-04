// Escrow archives of the offline build closure. The shared cache already holds
// everything an offline build needs — content-addressed blobs, extracted
// toolchain/sysroot trees, the apt `-dev` set, vendored crates. An escrow
// archive packages that closure into one `.tar.zst` that `emb cache import`
// restores, so a product can be rebuilt years later from an owned copy rather
// than from mirrors that may be gone.

/// The manifest file carried inside an escrow archive.
const archiveManifestName = 'emb-archive.json';

/// The durable cache subdirectories that make up a build closure, in a stable
/// order. Excludes transient dirs (`tmp/`, lock dirs), which are added as tar
/// excludes at pack time.
const durableCacheDirs = ['cas', 'store', 'apt', 'cargo-vendor', 'pub-cache'];

/// The cache subdirectories to include for an escrow archive. A `--cas-only`
/// archive keeps just the content-addressed blobs — roughly half the size,
/// since the store trees re-extract from those blobs on an offline resolve — a
/// full archive also ships the extracted trees so a restore needs no
/// re-extraction.
List<String> archiveDirs({required bool casOnly}) =>
    casOnly ? const ['cas'] : durableCacheDirs;

/// The archive's self-describing manifest: schema, the emb version that wrote
/// it, whether it is cas-only, the included dirs, and an ISO-8601 [created]
/// stamp. Content-addressed blobs make the archive self-verifying on restore,
/// so this is provenance rather than a trust anchor.
Map<String, dynamic> archiveManifest({
  required String embVersion,
  required bool casOnly,
  required List<String> dirs,
  required String created,
}) => {
  'schema': 1,
  'emb_version': embVersion,
  'cas_only': casOnly,
  'dirs': dirs,
  'created': created,
};

/// `tar` args to pack [dirs] (relative to [root]) plus the manifest (from
/// [manifestDir]) into [archive] as a deterministic zstd tarball. Transient
/// state is excluded; a [epoch] (SOURCE_DATE_EPOCH) clamps mtimes.
List<String> exportTarArgs({
  required String archive,
  required String root,
  required List<String> dirs,
  required String manifestDir,
  int? epoch,
}) => [
  '--zstd',
  '--sort=name',
  '--numeric-owner',
  '--owner=0',
  '--group=0',
  if (epoch != null) ...['--mtime=@$epoch', '--clamp-mtime'],
  '--exclude=locks',
  '--exclude=tmp',
  '--exclude=*.part',
  '--exclude=*.lock',
  '-cf',
  archive,
  '-C',
  root,
  ...dirs,
  '-C',
  manifestDir,
  archiveManifestName,
];

/// `tar` args to extract an escrow [archive] into the cache [root], merging
/// with whatever is already there (content-addressed entries are identical, so
/// overlap is safe).
List<String> importTarArgs({required String archive, required String root}) => [
  '--zstd',
  '-xf',
  archive,
  '-C',
  root,
];
