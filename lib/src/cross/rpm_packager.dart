import 'dart:io';

import 'package:emb_cli/src/cross/package_stager.dart';
import 'package:emb_cli/src/cross/process_runner.dart';
import 'package:path/path.dart' as p;

/// Spec metadata for a generated `.rpm`.
class RpmMetadata {
  const RpmMetadata({
    required this.name,
    required this.version,
    required this.architecture,
    required this.license,
    required this.summary,
    this.release = '1',
    this.group,
    this.requires = const [],
    this.scriptlets = const {},
  });

  final String name;
  final String version;

  /// rpm architecture (e.g. `aarch64`, `x86_64`), set as `BuildArch`.
  final String architecture;

  /// `License:` — mandatory; rpmbuild refuses to build without it.
  final String license;

  /// `Summary:` line.
  final String summary;

  /// `Release:` (defaults to `1`).
  final String release;

  /// Optional `Group:` tag.
  final String? group;

  /// Explicit `Requires:` entries (rpmbuild also auto-adds soname deps).
  final List<String> requires;

  /// Scriptlets keyed by maintainer-script name (`preinst`/`postinst`/`prerm`/
  /// `postrm`); the host file's body is inlined into the matching rpm section.
  final Map<String, String> scriptlets;
}

/// Thrown when packaging an `.rpm` fails.
class RpmPackageException implements Exception {
  RpmPackageException(this.message);
  final String message;
  @override
  String toString() => 'RpmPackageException: $message';
}

/// Builds an `.rpm` from a cross-built binary, via `rpmbuild`.
///
/// Sibling of the flatpak flow rather than the deb/ipk one: it stages the
/// payload (reusing `PackageStager`), emits a `.spec`, and lets `rpmbuild`
/// build the binary rpm into a private `_topdir` — rootless. The `scripts:`
/// map's four names translate to rpm scriptlets (`%pre`/`%post`/`%preun`/
/// `%postun`);
/// dependencies come from explicit `Requires:` plus rpm's own automatic soname
/// requires. Needs `rpmbuild` (from `rpm-build`) on the host.
class RpmPackager extends PackageStager {
  RpmPackager({ProcessRunner runProcess = defaultProcessRunner})
    : super(runProcess);

  /// Maps a maintainer-script name to the rpm scriptlet section keyword.
  static const _scriptlet = {
    'preinst': 'pre',
    'postinst': 'post',
    'prerm': 'preun',
    'postrm': 'postun',
  };

  @override
  Never fail(String message) => throw RpmPackageException(message);

  /// Package [binary] to `<outDir>/<name>-<version>-<release>.<arch>.rpm`,
  /// installing it at the absolute [installPath]. [extraFiles] maps host source
  /// paths to absolute target paths; both are listed in `%files`.
  Future<File> build({
    required File binary,
    required String installPath,
    required RpmMetadata meta,
    required Directory outDir,
    Map<String, String> extraFiles = const {},
    Map<String, String> fileModes = const {},
  }) async {
    if (meta.license.trim().isEmpty) {
      fail('rpm requires a license (set cross.package.rpm.license)');
    }
    for (final name in meta.scriptlets.keys) {
      if (!_scriptlet.containsKey(name)) {
        fail(
          'unknown maintainer script "$name" '
          '(expected one of: ${_scriptlet.keys.join(", ")})',
        );
      }
    }
    if (await _which('rpmbuild') == null) {
      fail(
        'rpmbuild not found on PATH — install rpm-build (which provides '
        'rpmbuild) to package .rpm files.',
      );
    }

    // Stage the payload (rooted at the target's /) into its own dir — NOT the
    // rpm buildroot, which rpmbuild wipes at the start of %install. The spec's
    // %install copies this tree into %{buildroot} instead.
    final payload = await stagePayload(
      binary: binary,
      installPath: installPath,
      packageName: meta.name,
      outDir: outDir,
      extraFiles: extraFiles,
      fileModes: fileModes,
    );

    // rpmbuild needs a private _topdir; RPMS/ is where the .rpm lands.
    final topDir = Directory(p.join(outDir.path, '${meta.name}.rpmbuild'));
    if (topDir.existsSync()) topDir.deleteSync(recursive: true);
    topDir.createSync(recursive: true);

    final paths = [installPath, ...extraFiles.values];
    final spec = File(p.join(topDir.path, '${meta.name}.spec'))
      ..writeAsStringSync(await _spec(meta, paths, payload));

    final r = await run('rpmbuild', [
      '-bb',
      '--define',
      '_topdir ${topDir.path}',
      '--target',
      meta.architecture,
      spec.path,
    ], output: ProcessOutputMode.stream);
    if (r.exitCode != 0) {
      payload.deleteSync(recursive: true);
      topDir.deleteSync(recursive: true);
      throw RpmPackageException('rpmbuild failed: ${r.stderr}');
    }

    final out = File(
      p.join(
        outDir.path,
        '${meta.name}-${meta.version}-${meta.release}.'
        '${meta.architecture}.rpm',
      ),
    );
    final built = File(
      p.join(
        topDir.path,
        'RPMS',
        meta.architecture,
        '${meta.name}-${meta.version}-${meta.release}.'
            '${meta.architecture}.rpm',
      ),
    );
    if (!built.existsSync()) {
      payload.deleteSync(recursive: true);
      topDir.deleteSync(recursive: true);
      throw RpmPackageException('rpmbuild did not produce ${built.path}');
    }
    built.copySync(out.path);
    payload.deleteSync(recursive: true);
    topDir.deleteSync(recursive: true);
    return out;
  }

  /// The `.spec`: metadata header, an `%install` that copies the staged
  /// [payload] into `%{buildroot}`, scriptlets from the metadata, and a
  /// `%files` list. The binary-mangling post-steps (strip/debuginfo/compress)
  /// are disabled — the payload is a pre-built (often foreign-arch) binary rpm
  /// must ship verbatim.
  Future<String> _spec(
    RpmMetadata m,
    List<String> paths,
    Directory payload,
  ) async {
    final b = StringBuffer()
      // Ship the cross-built binary as-is: no strip, no debuginfo subpackage,
      // no brp-* post-processing (which would run host tools on a foreign ELF).
      ..writeln('%global __os_install_post %{nil}')
      ..writeln('%global debug_package %{nil}')
      ..writeln('Name: ${m.name}')
      ..writeln('Version: ${m.version}')
      ..writeln('Release: ${m.release}')
      ..writeln('Summary: ${m.summary}')
      ..writeln('License: ${m.license}')
      ..writeln('BuildArch: ${m.architecture}');
    if (m.group != null) b.writeln('Group: ${m.group}');
    for (final req in m.requires) {
      b.writeln('Requires: $req');
    }
    b
      ..writeln()
      ..writeln('%description')
      ..writeln(m.summary)
      ..writeln()
      // Copy the pre-staged payload tree into rpm's buildroot.
      ..writeln('%install')
      ..writeln('mkdir -p %{buildroot}')
      ..writeln("cp -a '${payload.path}'/. %{buildroot}/")
      ..writeln();

    for (final entry in m.scriptlets.entries) {
      final src = File(entry.value);
      if (!src.existsSync()) {
        fail('maintainer script not found: ${entry.value}');
      }
      b
        ..writeln('%${_scriptlet[entry.key]}')
        ..writeln(src.readAsStringSync().trimRight())
        ..writeln();
    }

    b.writeln('%files');
    for (final path in paths) {
      b.writeln(path);
    }
    return b.toString();
  }

  /// Locate [exe] on PATH (`command -v`), or null when absent.
  Future<String?> _which(String exe) async {
    final r = await run('command', ['-v', exe], runInShell: true);
    if (r.exitCode != 0) return null;
    final out = r.stdout.trim();
    return out.isEmpty ? null : out;
  }
}
