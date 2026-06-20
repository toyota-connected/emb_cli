// Minimal Debian apt dependency resolution for root-free `-dev` population:
// parse a `Packages` index + the sysroot's installed set, then walk the
// dependency closure of the requested top-level packages. Just enough of apt's
// model (Depends/Pre-Depends, Provides/virtual packages, `a | b` alternatives,
// already-installed pruning) to gather the `.deb` set a `-dev` build needs —
// not a full solver (no version arithmetic or conflict handling).

/// One entry from a Debian `Packages` index.
class AptPackage {
  const AptPackage({
    required this.name,
    required this.filename,
    required this.repoBase,
    this.depends = const [],
    this.provides = const [],
  });

  final String name;

  /// `Filename:` — the `.deb` path relative to [repoBase].
  final String filename;

  /// Repository root the package is downloaded from (`<repoBase>/<filename>`).
  final String repoBase;

  final List<String> depends;
  final List<String> provides;

  String get url => '$repoBase/$filename';
}

/// A parsed (and possibly merged) `Packages` index.
class AptIndex {
  AptIndex([Map<String, AptPackage>? packages, Map<String, String>? provides])
    : packages = packages ?? {},
      provides = provides ?? {};

  /// Real packages by name.
  final Map<String, AptPackage> packages;

  /// Virtual package (`Provides`) → a concrete providing package name.
  final Map<String, String> provides;

  /// Merge [other] in (first writer wins, matching apt's repo priority order).
  void addAll(AptIndex other) {
    other.packages.forEach((k, v) => packages.putIfAbsent(k, () => v));
    other.provides.forEach((k, v) => provides.putIfAbsent(k, () => v));
  }

  /// Resolve [roots] to the closure of real [AptPackage]s to install. Explicit
  /// roots are always included; their transitive deps skip names in [satisfied]
  /// (already in the sysroot) and unknown/essential names not in the index.
  List<AptPackage> closure(
    Iterable<String> roots, {
    Set<String> satisfied = const {},
  }) {
    final out = <String, AptPackage>{};
    final stack = <String>[];

    // Explicit roots are always staged, even when dpkg-status marks them
    // installed: a device image often records a package installed yet strips
    // its files (e.g. a KDE image keeping `linux-libc-dev` in the status DB but
    // dropping `/usr/include/drm/*`), which a cross sysroot still needs. Their
    // transitive deps below keep the already-installed prune.
    for (final raw in roots) {
      final pkg = _lookup(raw);
      if (pkg == null || out.containsKey(pkg.name)) continue;
      out[pkg.name] = pkg;
      stack.addAll(pkg.depends);
    }

    while (stack.isNotEmpty) {
      final raw = stack.removeLast();
      if (satisfied.contains(raw) || out.containsKey(raw)) continue;
      final pkg = _lookup(raw);
      if (pkg == null) continue; // unknown / base / essential → assume present
      if (satisfied.contains(pkg.name) || out.containsKey(pkg.name)) continue;
      out[pkg.name] = pkg;
      stack.addAll(pkg.depends);
    }
    return out.values.toList();
  }

  /// Resolve a dependency token to a real package: directly, or via a virtual
  /// `Provides`.
  AptPackage? _lookup(String raw) =>
      packages[raw] ?? (provides[raw] != null ? packages[provides[raw]] : null);
}

/// Parse a Debian `Packages` index whose `.deb`s live under [repoBase].
AptIndex parsePackagesIndex(String text, {required String repoBase}) {
  final index = AptIndex();
  for (final stanza in text.split(RegExp(r'\n[ \t]*\n'))) {
    final fields = _stanzaFields(stanza);
    final name = fields['Package'];
    final filename = fields['Filename'];
    if (name == null || filename == null) continue;
    final depends = _depNames(
      '${fields['Pre-Depends'] ?? ''},${fields['Depends'] ?? ''}',
    );
    final prov = _depNames(fields['Provides'] ?? '');
    index.packages[name] = AptPackage(
      name: name,
      filename: filename,
      repoBase: repoBase,
      depends: depends,
      provides: prov,
    );
    for (final v in prov) {
      index.provides.putIfAbsent(v, () => name);
    }
  }
  return index;
}

/// Compressed `Packages`-index URLs for [arch], parsed from a sysroot's apt
/// sources. Handles both the classic one-line `deb` format and the deb822
/// `Types:/URIs:/Suites:/Components:` stanzas used by trixie/raspios. One URL
/// per (source, component); `deb-src`, disabled entries, comments, and blanks
/// are skipped.
List<String> aptIndexUrls(String sourcesText, String arch) {
  final urls = <String>[];
  // Process blank-line-separated stanzas so deb822 entries (multi-line) don't
  // bleed into one-line parsing. _readAptSources separates files with a blank
  // line, so a one-line sources.list and a deb822 *.sources never mix.
  for (final stanza in sourcesText.split(RegExp(r'\n[ \t]*\n'))) {
    if (RegExp(r'^[ \t]*Types[ \t]*:', multiLine: true).hasMatch(stanza)) {
      urls.addAll(_deb822IndexUrls(stanza, arch));
    } else {
      for (final line in stanza.split('\n')) {
        urls.addAll(_oneLineIndexUrls(line, arch));
      }
    }
  }
  return urls;
}

/// One classic `deb [opts] <uri> <suite> <comp...>` line -> binary index URLs.
List<String> _oneLineIndexUrls(String line, String arch) {
  final t = line.trim();
  if (!t.startsWith('deb ')) return const [];
  var toks = t.substring(4).trim().split(RegExp(r'\s+'));
  if (toks.isNotEmpty && toks.first.startsWith('[')) {
    var i = 0;
    while (i < toks.length && !toks[i].endsWith(']')) {
      i++;
    }
    toks = i + 1 < toks.length ? toks.sublist(i + 1) : const [];
  }
  if (toks.length < 3) return const [];
  final uri = toks[0];
  final suite = toks[1];
  return [
    for (final comp in toks.sublist(2))
      '$uri/dists/$suite/$comp/binary-$arch/Packages.xz',
  ];
}

/// A deb822 stanza (`Types:`/`URIs:`/`Suites:`/`Components:`, as used by
/// trixie/raspios) -> binary index URLs for each URI x Suite x Component.
List<String> _deb822IndexUrls(String stanza, String arch) {
  final fields = <String, String>{};
  String? key;
  for (final line in stanza.split('\n')) {
    final m = RegExp(
      r'^([A-Za-z][A-Za-z-]*)[ \t]*:[ \t]*(.*)$',
    ).firstMatch(line);
    if (m != null) {
      key = m.group(1);
      fields[key!] = (m.group(2) ?? '').trim();
    } else if (key != null && (line.startsWith(' ') || line.startsWith('\t'))) {
      fields[key] = '${fields[key]} ${line.trim()}'.trim();
    }
  }
  List<String> values(String k) => (fields[k] ?? '')
      .split(RegExp(r'\s+'))
      .where((s) => s.isNotEmpty)
      .toList();
  if (!values('Types').contains('deb')) return const [];
  if ((fields['Enabled'] ?? 'yes').toLowerCase() == 'no') return const [];
  final out = <String>[];
  for (final uri in values('URIs')) {
    final base = uri.replaceFirst(RegExp(r'/+$'), '');
    for (final suite in values('Suites')) {
      for (final comp in values('Components')) {
        out.add('$base/dists/$suite/$comp/binary-$arch/Packages.xz');
      }
    }
  }
  return out;
}

/// Names already installed in a sysroot's `/var/lib/dpkg/status` (plus what
/// they Provide) — treated as already satisfied so they aren't re-downloaded.
Set<String> parseInstalled(String statusText) {
  final installed = <String>{};
  for (final stanza in statusText.split(RegExp(r'\n[ \t]*\n'))) {
    final fields = _stanzaFields(stanza);
    final name = fields['Package'];
    if (name == null || !(fields['Status'] ?? '').contains('installed')) {
      continue;
    }
    installed
      ..add(name)
      ..addAll(_depNames(fields['Provides'] ?? ''));
  }
  return installed;
}

Map<String, String> _stanzaFields(String stanza) {
  final fields = <String, String>{};
  String? key;
  for (final line in stanza.split('\n')) {
    if (line.isEmpty) continue;
    if ((line.startsWith(' ') || line.startsWith('\t')) && key != null) {
      fields[key] = '${fields[key]} ${line.trim()}';
      continue;
    }
    final i = line.indexOf(':');
    if (i <= 0) continue;
    key = line.substring(0, i);
    fields[key] = line.substring(i + 1).trim();
  }
  return fields;
}

/// A Depends/Provides field → bare package names: alternatives (`a | b`)
/// reduced to the first, and version/arch/profile/multiarch qualifiers
/// (`(>= 1)`, `[arch]`, `<profile>`, `:any`) stripped.
List<String> _depNames(String field) {
  final out = <String>[];
  for (final clause in field.split(',')) {
    final first = clause.split('|').first.trim();
    if (first.isEmpty) continue;
    final name = first.split(RegExp(r'[\s(:\[<]')).first.trim();
    if (name.isNotEmpty) out.add(name);
  }
  return out;
}
