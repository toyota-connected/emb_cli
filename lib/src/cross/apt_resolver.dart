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

  /// Resolve [roots] to the closure of real [AptPackage]s to install, skipping
  /// names in [satisfied] (already in the sysroot) and unknown/essential names
  /// not in the index.
  List<AptPackage> closure(
    Iterable<String> roots, {
    Set<String> satisfied = const {},
  }) {
    final out = <String, AptPackage>{};
    final stack = [...roots];
    while (stack.isNotEmpty) {
      final raw = stack.removeLast();
      if (satisfied.contains(raw) || out.containsKey(raw)) continue;
      final pkg =
          packages[raw] ??
          (provides[raw] != null ? packages[provides[raw]] : null);
      if (pkg == null) continue; // unknown / base / essential → assume present
      if (satisfied.contains(pkg.name) || out.containsKey(pkg.name)) continue;
      out[pkg.name] = pkg;
      stack.addAll(pkg.depends);
    }
    return out.values.toList();
  }
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
/// sources (the one-line `deb [opts] <uri> <suite> <comp>...` format). One URL
/// per (source, component). `deb-src`, comments, and blanks are skipped.
List<String> aptIndexUrls(String sourcesText, String arch) {
  final urls = <String>[];
  for (final line in sourcesText.split('\n')) {
    final t = line.trim();
    if (!t.startsWith('deb ')) continue;
    var toks = t.substring(4).trim().split(RegExp(r'\s+'));
    if (toks.isNotEmpty && toks.first.startsWith('[')) {
      var i = 0;
      while (i < toks.length && !toks[i].endsWith(']')) {
        i++;
      }
      toks = i + 1 < toks.length ? toks.sublist(i + 1) : const [];
    }
    if (toks.length < 3) continue;
    final uri = toks[0];
    final suite = toks[1];
    for (final comp in toks.sublist(2)) {
      urls.add('$uri/dists/$suite/$comp/binary-$arch/Packages.xz');
    }
  }
  return urls;
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
