import 'dart:io';

import 'package:emb_cli/src/cross/process_runner.dart';
import 'package:path/path.dart' as p;

/// Control metadata for a generated `.deb`.
class DebMetadata {
  const DebMetadata({
    required this.name,
    required this.version,
    required this.architecture,
    required this.maintainer,
    required this.description,
    this.section = 'misc',
    this.priority = 'optional',
    this.dependsExtra = const [],
    this.autoDepends = true,
  });

  final String name;
  final String version;

  /// Debian architecture (e.g. `arm64`), not the GNU triple.
  final String architecture;
  final String maintainer;
  final String description;
  final String section;
  final String priority;

  /// Explicit `Depends` entries, merged with the auto-derived set.
  final List<String> dependsExtra;

  /// Derive `Depends` from the binary's `DT_NEEDED` shared libraries,
  /// mapped to the packages that own them.
  final bool autoDepends;
}

/// Thrown when packaging a `.deb` fails.
class DebPackageException implements Exception {
  DebPackageException(this.message);
  final String message;
  @override
  String toString() => 'DebPackageException: $message';
}

/// Builds a Debian `.deb` from a cross-built binary — **root-free** via
/// `dpkg-deb --root-owner-group`. `Depends` is derived from the binary's
/// `DT_NEEDED` entries (read with the cross `readelf`) mapped to the owning
/// packages, using both the sysroot's dpkg database (base image) and the
/// resolver-downloaded `.deb`s (the `-dev` closure), so the field reflects what
/// `apt install ./pkg.deb` must pull on the target.
class DebPackager {
  DebPackager({
    required this.readelf,
    ProcessRunner runProcess = defaultProcessRunner,
  }) : _run = runProcess;

  /// Path to the cross `readelf` (reads target-arch ELF `DT_NEEDED`).
  final String readelf;
  final ProcessRunner _run;

  /// Package [binary] to `<outDir>/<name>_<version>_<arch>.deb`, installing it
  /// at the absolute [installPath] on the target. [sysroot] and [debDirs] feed
  /// the package-ownership lookup for auto `Depends`.
  Future<File> build({
    required File binary,
    required String installPath,
    required DebMetadata meta,
    required Directory outDir,
    Directory? sysroot,
    List<Directory> debDirs = const [],
  }) async {
    if (!binary.existsSync()) {
      throw DebPackageException('binary not found: ${binary.path}');
    }
    if (!p.isAbsolute(installPath)) {
      throw DebPackageException('install path must be absolute: $installPath');
    }

    final depends = {...meta.dependsExtra};
    if (meta.autoDepends) {
      depends.addAll(await _autoDepends(binary, sysroot, debDirs));
    }
    final deps = depends.toList()..sort();

    outDir.createSync(recursive: true);
    final stage = Directory(p.join(outDir.path, '${meta.name}.stage'));
    if (stage.existsSync()) stage.deleteSync(recursive: true);
    // Install the binary at the requested path inside the staging root.
    final dest = File(p.join(stage.path, installPath.substring(1)))
      ..parent.createSync(recursive: true);
    binary.copySync(dest.path);
    await _run('chmod', ['0755', dest.path]);

    File(p.join(stage.path, 'DEBIAN', 'control'))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(_control(meta, deps));

    final out = File(
      p.join(
        outDir.path,
        '${meta.name}_${meta.version}_${meta.architecture}.deb',
      ),
    );
    final r = await _run('dpkg-deb', [
      '--root-owner-group',
      '--build',
      stage.path,
      out.path,
    ]);
    stage.deleteSync(recursive: true);
    if (r.exitCode != 0) {
      throw DebPackageException('dpkg-deb --build failed: ${r.stderr}');
    }
    return out;
  }

  String _control(DebMetadata m, List<String> depends) {
    final b = StringBuffer()
      ..writeln('Package: ${m.name}')
      ..writeln('Version: ${m.version}')
      ..writeln('Architecture: ${m.architecture}')
      ..writeln('Maintainer: ${m.maintainer}')
      ..writeln('Section: ${m.section}')
      ..writeln('Priority: ${m.priority}');
    if (depends.isNotEmpty) b.writeln('Depends: ${depends.join(', ')}');
    // Debian requires a synopsis line; indent any continuation.
    b.writeln('Description: ${m.description}');
    return b.toString();
  }

  /// The owning packages of the binary's `DT_NEEDED` shared libraries.
  Future<Set<String>> _autoDepends(
    File binary,
    Directory? sysroot,
    List<Directory> debDirs,
  ) async {
    final needed = await _needed(binary);
    if (needed.isEmpty) return {};
    final owners = <String>{};
    final unresolved = {...needed};

    // Base-image packages: the sysroot's dpkg `.list` files.
    if (sysroot != null) {
      final info = Directory(
        p.join(sysroot.path, 'var', 'lib', 'dpkg', 'info'),
      );
      if (info.existsSync()) {
        for (final f in info.listSync().whereType<File>()) {
          if (!f.path.endsWith('.list')) continue;
          final pkg = p
              .basename(f.path)
              .replaceFirst(RegExp(r'\.list$'), '')
              .split(':')
              .first;
          for (final line in f.readAsLinesSync()) {
            final base = p.basename(line);
            if (unresolved.remove(base)) owners.add(pkg);
          }
          if (unresolved.isEmpty) break;
        }
      }
    }

    // Resolver `-dev` closure: scan the downloaded `.deb`s until resolved.
    for (final dir in debDirs) {
      if (unresolved.isEmpty) break;
      if (!dir.existsSync()) continue;
      for (final deb in dir.listSync().whereType<File>()) {
        if (unresolved.isEmpty) break;
        if (!deb.path.endsWith('.deb') || deb.lengthSync() == 0) continue;
        final contents = await _run('dpkg-deb', ['-c', deb.path]);
        if (contents.exitCode != 0) continue;
        final hit = _sonamesIn('${contents.stdout}').intersection(unresolved);
        if (hit.isEmpty) continue;
        final field = await _run('dpkg-deb', ['-f', deb.path, 'Package']);
        final pkg = '${field.stdout}'.trim();
        if (pkg.isNotEmpty) {
          owners.add(pkg);
          unresolved.removeAll(hit);
        }
      }
    }
    return owners;
  }

  /// `DT_NEEDED` sonames of [binary] via `readelf -d`.
  Future<List<String>> _needed(File binary) async {
    final r = await _run(readelf, ['-d', binary.path]);
    if (r.exitCode != 0) {
      throw DebPackageException('readelf -d failed: ${r.stderr}');
    }
    final re = RegExp(r'Shared library:\s*\[([^\]]+)\]');
    return [for (final m in re.allMatches('${r.stdout}')) m.group(1)!];
  }

  /// Basenames of the shared-object entries in `dpkg-deb -c` output.
  Set<String> _sonamesIn(String contents) {
    final out = <String>{};
    for (final line in contents.split('\n')) {
      final tok = line
          .split(RegExp(r'\s+'))
          .firstWhere((t) => t.startsWith('./'), orElse: () => '');
      if (tok.isEmpty) continue;
      final base = p.basename(tok);
      if (base.contains('.so')) out.add(base);
    }
    return out;
  }
}
