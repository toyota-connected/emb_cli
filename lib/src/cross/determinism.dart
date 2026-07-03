import 'dart:io';

import 'package:path/path.dart' as p;

/// `SOURCE_DATE_EPOCH` from [env] (the process environment by default) as a
/// non-negative int, or null when unset or unparseable. Packagers use it to
/// stamp deterministic timestamps; the value is supplied by the caller/CI (and
/// inherited by child tools such as `dpkg-deb`/`rpmbuild`), never invented by
/// emb.
int? sourceDateEpoch([Map<String, String>? env]) {
  final v = (env ?? Platform.environment)['SOURCE_DATE_EPOCH'];
  if (v == null) return null;
  final n = int.tryParse(v.trim());
  return (n == null || n < 0) ? null : n;
}

/// Absolute host paths that would otherwise be baked into compiled output —
/// the target [sysroot] and the toolchain [crossBin] — mapped to stable
/// tokens. Both live under a machine-specific cache root (`~/.cache/emb/…`), so
/// without this the same source compiles to different bytes on different hosts.
///
/// Only cross builds (those with a real target [sysroot]) are canonicalized;
/// native desktop builds return an empty map so their artifacts keep real paths
/// and a debugger can still resolve sources.
Map<String, String> toolchainPrefixMap({
  required String sysroot,
  required String crossBin,
}) {
  if (sysroot.isEmpty || !p.isAbsolute(sysroot)) return const {};
  return {
    sysroot: '/emb/sysroot',
    if (crossBin.isNotEmpty && p.isAbsolute(crossBin))
      crossBin: '/emb/toolchain',
  };
}

/// `-ffile-prefix-map`/`-fdebug-prefix-map` compiler flags for [map] — they
/// rewrite each host path out of `__FILE__`, DWARF, and diagnostics so the
/// output no longer records where it was built.
List<String> prefixMapFlags(Map<String, String> map) => [
  for (final e in map.entries) ...[
    '-ffile-prefix-map=${e.key}=${e.value}',
    '-fdebug-prefix-map=${e.key}=${e.value}',
  ],
];

/// The rustc equivalent of [prefixMapFlags]: one `--remap-path-prefix` per
/// entry, for the Rust half of a cargo module's compilation.
List<String> rustRemapArgs(Map<String, String> map) => [
  for (final e in map.entries) '--remap-path-prefix=${e.key}=${e.value}',
];
