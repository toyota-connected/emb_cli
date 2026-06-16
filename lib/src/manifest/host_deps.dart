import 'package:emb_cli/src/host/host_info.dart';

/// A single conditional rule contributing host OS package names.
///
/// Both the new structured `emb` schema and the legacy
/// `runtime.pre-requisites[arch][distro][version]` schema are normalized into
/// a flat list of these rules so the coalesce/filter stage can evaluate them
/// uniformly against a [HostInfo].
class DepRule {
  const DepRule({
    required this.os,
    required this.packages,
    this.hostType,
    this.versionId,
    this.arch,
  });

  /// OS family this rule applies to.
  final HostOs os;

  /// Distro id (e.g. `fedora`, `ubuntu`) this rule applies to; `null` matches
  /// any distro/host-type on [os].
  final String? hostType;

  /// OS version id this rule applies to; `null` matches any version.
  final String? versionId;

  /// Machine arch token this rule applies to; `null` matches any arch.
  final String? arch;

  /// Package names contributed when this rule matches.
  final List<String> packages;

  /// Whether this rule applies to [host].
  bool matches(HostInfo host) {
    if (os != host.os) return false;
    if (hostType != null && hostType!.toLowerCase() != host.hostType) {
      return false;
    }
    if (versionId != null && versionId != host.versionId) return false;
    if (arch != null && !host.archAliases.contains(arch!.toLowerCase())) {
      return false;
    }
    return true;
  }

  @override
  String toString() =>
      'DepRule(${os.name}'
      '${hostType != null ? "/$hostType" : ""}'
      '${versionId != null ? "/$versionId" : ""}'
      '${arch != null ? "@$arch" : ""}: ${packages.join(" ")})';
}

/// The set of host OS package dependencies declared by a manifest, normalized
/// into [DepRule]s.
class HostDeps {
  const HostDeps(this.rules);

  /// Parse the new structured `deps` map:
  /// ```yaml
  /// deps:
  ///   linux:
  ///     fedora: [pkg-config, freetype-devel]
  ///     ubuntu: [pkg-config, libfreetype-dev]
  ///   macos: [pkg-config, freetype]
  ///   windows: [Kitware.CMake]
  /// ```
  /// A value that is a list applies to any distro on that OS; a value that is
  /// a map keys package lists by distro id (Linux) or is ignored otherwise.
  factory HostDeps.fromStructured(Map<dynamic, dynamic> deps) {
    final rules = <DepRule>[];
    for (final entry in deps.entries) {
      final os = _osFromToken(entry.key.toString());
      if (os == null) continue;
      final value = entry.value;
      if (value is List) {
        rules.add(DepRule(os: os, packages: _stringList(value)));
      } else if (value is Map) {
        for (final sub in value.entries) {
          final pkgs = sub.value;
          if (pkgs is List) {
            rules.add(
              DepRule(
                os: os,
                hostType: sub.key.toString().toLowerCase(),
                packages: _stringList(pkgs),
              ),
            );
          }
        }
      }
    }
    return HostDeps(rules);
  }

  /// Parse the legacy `runtime.pre-requisites[arch][distro]{cmds,[version]}`
  /// schema, extracting OS package names from the inline `sudo … install`
  /// command strings. Mirrors `handle_pre_requisites`.
  factory HostDeps.fromLegacyPreRequisites(Map<dynamic, dynamic> prereq) {
    final rules = <DepRule>[];
    for (final archEntry in prereq.entries) {
      final arch = archEntry.key.toString();
      final byDistro = archEntry.value;
      if (byDistro is! Map) continue;
      for (final distroEntry in byDistro.entries) {
        final distro = distroEntry.key.toString().toLowerCase();
        final os = _osFromToken(distro);
        if (os == null) continue;
        final distroMap = distroEntry.value;
        if (distroMap is! Map) continue;

        // Distro-level cmds apply to all versions of this distro+arch.
        final distroPkgs = _packagesFromCmds(distroMap['cmds']);
        if (distroPkgs.isNotEmpty) {
          rules.add(
            DepRule(os: os, arch: arch, hostType: distro, packages: distroPkgs),
          );
        }

        // Version-specific nested cmds (keys that are version ids).
        for (final inner in distroMap.entries) {
          final key = inner.key.toString();
          if (key == 'cmds' || key == 'conditionals') continue;
          final versionMap = inner.value;
          if (versionMap is! Map) continue;
          final versionPkgs = _packagesFromCmds(versionMap['cmds']);
          if (versionPkgs.isNotEmpty) {
            rules.add(
              DepRule(
                os: os,
                arch: arch,
                hostType: distro,
                versionId: key,
                packages: versionPkgs,
              ),
            );
          }
        }
      }
    }
    return HostDeps(rules);
  }

  /// The normalized dependency rules.
  final List<DepRule> rules;

  /// An empty dependency set.
  static const HostDeps empty = HostDeps([]);

  bool get isEmpty => rules.isEmpty;

  /// All package names that apply to [host], de-duplicated, order preserved.
  List<String> resolve(HostInfo host) {
    final out = <String>{};
    for (final rule in rules) {
      if (rule.matches(host)) out.addAll(rule.packages);
    }
    return out.toList();
  }

  static List<String> _packagesFromCmds(dynamic cmds) {
    if (cmds is! List) return const [];
    final out = <String>[];
    for (final cmd in cmds) {
      out.addAll(extractPackageNames(cmd.toString()));
    }
    return out;
  }

  static List<String> _stringList(List<dynamic> list) =>
      list.map((e) => e.toString()).toList();

  static HostOs? _osFromToken(String token) {
    switch (token.toLowerCase()) {
      case 'linux':
      case 'fedora':
      case 'ubuntu':
      case 'debian':
      case 'rhel':
      case 'centos':
      case 'opensuse':
      case 'opensuse-leap':
      case 'opensuse-tumbleweed':
      case 'arch':
        return HostOs.linux;
      case 'darwin':
      case 'macos':
        return HostOs.macos;
      case 'windows':
        return HostOs.windows;
      default:
        return null;
    }
  }
}

/// Package managers whose `install` invocations carry OS package names.
const _knownManagers = {
  'apt',
  'apt-get',
  'dnf',
  'microdnf',
  'yum',
  'zypper',
  'pacman',
  'brew',
  'winget',
  'choco',
};

/// Extract OS package names from a single shell command string such as
/// `sudo dnf -y install libffi-devel libxml2-devel`.
///
/// Returns an empty list for commands that are not package-manager installs
/// (e.g. `pip3 install meson`, `git ...`, `meson setup ...`). This is the
/// migration path from the legacy inline `sudo … install` strings to the
/// structured, coalesce-able package-name lists.
List<String> extractPackageNames(String command) {
  // Only consider simple commands; skip anything with shell plumbing that we
  // cannot safely interpret as a flat install line.
  final tokens = command
      .trim()
      .split(RegExp(r'\s+'))
      .where((t) => t.isNotEmpty)
      .toList();
  if (tokens.isEmpty) return const [];

  var i = 0;
  if (tokens[i] == 'sudo') i++;
  if (i >= tokens.length) return const [];

  final manager = tokens[i];
  if (!_knownManagers.contains(manager)) return const [];
  i++;

  // Find the install subcommand (`install`, or pacman's `-S`).
  var sawInstall = false;
  final packages = <String>[];
  for (; i < tokens.length; i++) {
    final tok = tokens[i];
    if (!sawInstall) {
      if (tok == 'install' || tok == '-S' || tok == '-Sy' || tok == '-Syu') {
        sawInstall = true;
      }
      continue;
    }
    // After `install`: skip flags and option-with-value pairs.
    if (tok.startsWith('-')) continue;
    // Stop at shell separators if any slipped through.
    if (tok == '&&' || tok == '||' || tok == '|' || tok == ';') break;
    packages.add(tok);
  }
  return sawInstall ? packages : const [];
}
