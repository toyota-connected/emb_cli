// Minimal Alpine `apk` dependency resolution for root-free musl `-dev` sysroot
// population — the musl analog of `apt_resolver.dart`. Parse an `APKINDEX` (the
// text inside `APKINDEX.tar.gz`) and walk the dependency closure of the
// requested top-level packages, resolving `so:` / `pc:` / `cmd:` virtuals via
// `provides`. Not a full solver (no version arithmetic or conflicts).

/// One record from an `APKINDEX`.
class ApkPackage {
  const ApkPackage({
    required this.name,
    required this.version,
    required this.repoBase,
    this.arch,
    this.checksum,
    this.depends = const [],
    this.provides = const [],
  });

  final String name;

  /// `V:` — the exact version, so a resolve can be pinned and later re-resolves
  /// can detect a mirror serving different bytes.
  final String version;

  /// Repository root the `.apk` is downloaded from
  /// (`<mirror>/<branch>/<repo>/<arch>`).
  final String repoBase;

  /// `A:` — the package architecture.
  final String? arch;

  /// `C:` — the index-advertised checksum (`Q1<base64-sha1>`).
  final String? checksum;

  /// `D:` dependency tokens, stripped of version constraints and `!conflicts`.
  final List<String> depends;

  /// `p:` provide tokens (bare names + `so:`/`pc:`/`cmd:` virtuals), stripped
  /// of `=version`.
  final List<String> provides;

  /// The `.apk` file name (`<name>-<version>.apk`).
  String get filename => '$name-$version.apk';

  /// The `.apk` download URL.
  String get url => '$repoBase/$filename';
}

/// A parsed (and possibly merged) `APKINDEX`.
class ApkIndex {
  ApkIndex([Map<String, ApkPackage>? packages, Map<String, String>? provides])
    : packages = packages ?? {},
      provides = provides ?? {};

  /// Real packages by name.
  final Map<String, ApkPackage> packages;

  /// Provide token (bare name or `so:`/`pc:`/`cmd:` virtual) → providing package.
  final Map<String, String> provides;

  /// Merge [other] in (first writer wins, matching apk repo priority order).
  void addAll(ApkIndex other) {
    other.packages.forEach((k, v) => packages.putIfAbsent(k, () => v));
    other.provides.forEach((k, v) => provides.putIfAbsent(k, () => v));
  }

  /// Resolve [roots] to the closure of real [ApkPackage]s. Explicit roots are
  /// always included; their transitive deps skip names in [satisfied] (already
  /// in the sysroot) and unknown virtuals not in the index.
  List<ApkPackage> closure(
    Iterable<String> roots, {
    Set<String> satisfied = const {},
  }) {
    final out = <String, ApkPackage>{};
    final stack = <String>[];

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
      if (pkg == null) continue; // unknown virtual / base → assume present
      if (satisfied.contains(pkg.name) || out.containsKey(pkg.name)) continue;
      out[pkg.name] = pkg;
      stack.addAll(pkg.depends);
    }
    return out.values.toList();
  }

  ApkPackage? _lookup(String raw) =>
      packages[raw] ?? (provides[raw] != null ? packages[provides[raw]] : null);
}

/// Strip an apk dependency/provide constraint (`>=`, `<`, `=`, `~`, `>`, `<`)
/// from [token], leaving the bare name/virtual.
String apkDepName(String token) {
  final m = RegExp('[<>=~]').firstMatch(token);
  return m == null ? token : token.substring(0, m.start);
}

/// Parse an `APKINDEX` text whose `.apk`s live under [repoBase].
ApkIndex parseApkIndex(String text, {required String repoBase}) {
  final index = ApkIndex();
  for (final record in text.split(RegExp(r'\n[ \t]*\n'))) {
    String? name;
    String? version;
    String? arch;
    String? checksum;
    final depends = <String>[];
    final provides = <String>[];
    for (final line in record.split('\n')) {
      if (line.length < 2 || line[1] != ':') continue;
      final value = line.substring(2).trim();
      switch (line[0]) {
        case 'P':
          name = value;
        case 'V':
          version = value;
        case 'A':
          arch = value;
        case 'C':
          checksum = value;
        case 'D':
          for (final t in value.split(RegExp(r'\s+'))) {
            if (t.isEmpty || t.startsWith('!')) continue; // skip conflicts
            depends.add(apkDepName(t));
          }
        case 'p':
          for (final t in value.split(RegExp(r'\s+'))) {
            if (t.isEmpty) continue;
            provides.add(apkDepName(t));
          }
      }
    }
    if (name == null || version == null) continue;
    index.packages[name] = ApkPackage(
      name: name,
      version: version,
      repoBase: repoBase,
      arch: arch,
      checksum: checksum,
      depends: depends,
      provides: provides,
    );
    index.provides.putIfAbsent(name, () => name!); // a package provides itself
    for (final v in provides) {
      index.provides.putIfAbsent(v, () => name!);
    }
  }
  return index;
}
