import 'dart:io';

import 'package:emb_cli/src/cross/process_runner.dart';
import 'package:path/path.dart' as p;

/// Manifest metadata for a generated `.flatpak` bundle.
///
/// A flatpak wraps the whole runnable bundle (embedder + `data/` + `lib/`) in a
/// sandboxed app under a reverse-DNS [appId], built against a freedesktop (or
/// custom) runtime. Defaults target a Wayland Flutter shell.
class FlatpakMetadata {
  const FlatpakMetadata({
    required this.appId,
    required this.command,
    this.branch = 'stable',
    this.runtime = 'org.freedesktop.Platform',
    this.runtimeVersion = '23.08',
    this.sdk = 'org.freedesktop.Sdk',
    this.arch,
    this.finishArgs = defaultFinishArgs,
    this.appName,
    this.icon,
    this.categories = const ['Utility'],
  });

  /// A reasonable sandbox for a Wayland Flutter shell: Wayland socket, GPU,
  /// audio, and shared IPC. Override via `cross.package.flatpak.finish_args`.
  static const List<String> defaultFinishArgs = [
    '--share=ipc',
    '--socket=wayland',
    '--socket=fallback-x11',
    '--device=dri',
    '--socket=pulseaudio',
  ];

  /// Reverse-DNS application id, e.g. `com.toyota.ivi.Homescreen`. Doubles as
  /// the install prefix (`/app/<appId>`), `.desktop` basename, and icon name.
  final String appId;

  /// The embedder binary (basename) the launcher wrapper execs with `-b`.
  final String command;

  final String branch;
  final String runtime;
  final String runtimeVersion;
  final String sdk;

  /// flatpak arch (`aarch64`, `x86_64`, `arm`); null builds for the host arch.
  final String? arch;

  /// Sandbox permissions (`finish-args`).
  final List<String> finishArgs;

  /// `.desktop` display name; defaults to the appId's last segment.
  final String? appName;

  /// Host path to a PNG/SVG icon installed into the hicolor theme. Optional.
  final File? icon;

  /// `.desktop` `Categories`.
  final List<String> categories;
}

/// Thrown when packaging a `.flatpak` fails.
class FlatpakPackageException implements Exception {
  FlatpakPackageException(this.message);
  final String message;
  @override
  String toString() => 'FlatpakPackageException: $message';
}

/// Builds a single-file `.flatpak` from a runnable bundle via
/// `flatpak-builder`.
///
/// Mirrors `DebPackager` in shape — stage, emit metadata, invoke the system
/// packaging tool — but a flatpak wraps the *whole* app: the bundle tree is
/// copied to `/app/<appId>`, a launcher wrapper (`exec <embedder> -b
/// <prefix>`) is installed on `PATH`, and a `.desktop` (+ optional icon) make
/// it a first-class sandboxed app. Extra files map host paths into the `/app`
/// prefix.
///
/// Needs `flatpak-builder` plus the target runtime/SDK installed on the build
/// host (`flatpak install org.freedesktop.Platform//<ver>` etc.); a missing
/// `flatpak-builder` is reported up front.
class FlatpakPackager {
  FlatpakPackager({ProcessRunner runProcess = defaultProcessRunner})
    : _run = runProcess;

  final ProcessRunner _run;

  /// Package [bundleDir] (embedder + `data/` + `lib/`) into
  /// `<outDir>/<appId>_<branch>_<arch>.flatpak`. [extraFiles] maps host source
  /// paths to destinations under the `/app` prefix (a leading `/` is treated as
  /// relative to `/app`).
  Future<File> build({
    required Directory bundleDir,
    required FlatpakMetadata meta,
    required Directory outDir,
    Map<String, String> extraFiles = const {},
  }) async {
    if (!bundleDir.existsSync()) {
      throw FlatpakPackageException('bundle not found: ${bundleDir.path}');
    }
    if (!File(p.join(bundleDir.path, meta.command)).existsSync()) {
      throw FlatpakPackageException(
        'embedder "${meta.command}" not found in ${bundleDir.path}',
      );
    }
    if (!_looksLikeAppId(meta.appId)) {
      throw FlatpakPackageException(
        'invalid flatpak app id "${meta.appId}" '
        '(need reverse-DNS, e.g. com.example.App)',
      );
    }
    if (await _which('flatpak-builder') == null) {
      final ver = meta.runtimeVersion;
      throw FlatpakPackageException(
        'flatpak-builder not found on PATH — install it plus the runtime, '
        'e.g.\n'
        '    flatpak install flathub '
        'org.freedesktop.Platform//$ver org.freedesktop.Sdk//$ver',
      );
    }

    outDir.createSync(recursive: true);
    final ctx = Directory(p.join(outDir.path, '${meta.appId}.flatpak-ctx'));
    if (ctx.existsSync()) ctx.deleteSync(recursive: true);
    ctx.createSync(recursive: true);

    // Stage the bundle tree the manifest's `dir` source copies from.
    await _copyTree(bundleDir, Directory(p.join(ctx.path, 'bundle')));

    // Launcher wrapper: run the embedder against its in-prefix bundle dir.
    final prefix = '/app/${meta.appId}';
    File(p.join(ctx.path, 'launcher.sh')).writeAsStringSync(
      '#!/bin/sh\n'
      'exec $prefix/${meta.command} -b $prefix "\$@"\n',
    );

    final desktopName = meta.appName ?? meta.appId.split('.').last;
    File(
      p.join(ctx.path, '${meta.appId}.desktop'),
    ).writeAsStringSync(_desktop(meta, desktopName));
    if (meta.icon != null) {
      if (!meta.icon!.existsSync()) {
        throw FlatpakPackageException('icon not found: ${meta.icon!.path}');
      }
      final ext = p.extension(meta.icon!.path);
      meta.icon!.copySync(p.join(ctx.path, 'icon$ext'));
    }

    // Stage extra files under extra/<n>, recording their /app destinations.
    final extras = <_Extra>[];
    if (extraFiles.isNotEmpty) {
      Directory(p.join(ctx.path, 'extra')).createSync();
    }
    var i = 0;
    for (final entry in extraFiles.entries) {
      final src = File(entry.key);
      if (!src.existsSync()) {
        throw FlatpakPackageException('extra file not found: ${entry.key}');
      }
      final staged = 'extra/$i';
      src.copySync(p.join(ctx.path, staged));
      extras.add(_Extra(staged, _appDest(entry.value)));
      i++;
    }

    final manifest = File(p.join(ctx.path, '${meta.appId}.yml'))
      ..writeAsStringSync(_manifest(meta, prefix, desktopName, extras));

    final repo = Directory(p.join(ctx.path, 'repo'));
    final builderArgs = [
      '--force-clean',
      '--disable-rofiles-fuse',
      '--repo=${repo.path}',
      if (meta.arch != null) '--arch=${meta.arch}',
      p.join(ctx.path, 'builddir'),
      manifest.path,
    ];
    final br = await _run(
      'flatpak-builder',
      builderArgs,
      workingDirectory: ctx.path,
    );
    if (br.exitCode != 0) {
      throw FlatpakPackageException('flatpak-builder failed: ${br.stderr}');
    }

    final out = File(
      p.join(
        outDir.path,
        '${meta.appId}_${meta.branch}_${meta.arch ?? "host"}.flatpak',
      ),
    );
    final bundleRes = await _run('flatpak', [
      'build-bundle',
      if (meta.arch != null) '--arch=${meta.arch}',
      repo.path,
      out.path,
      meta.appId,
      meta.branch,
    ]);
    if (bundleRes.exitCode != 0) {
      throw FlatpakPackageException(
        'flatpak build-bundle failed: ${bundleRes.stderr}',
      );
    }
    ctx.deleteSync(recursive: true);
    return out;
  }

  /// The flatpak-builder manifest (a `simple` module over a `dir` source).
  String _manifest(
    FlatpakMetadata m,
    String prefix,
    String desktopName,
    List<_Extra> extras,
  ) {
    final desktopDest = '/app/share/applications/${m.appId}.desktop';
    final iconDest =
        '/app/share/icons/hicolor/256x256/apps/${m.appId}${_iconExt(m.icon)}';
    final cmds = <String>[
      'mkdir -p $prefix',
      'cp -r bundle/. $prefix/',
      'chmod 0755 $prefix/${m.command}',
      'install -Dm755 launcher.sh /app/bin/${m.command}',
      'install -Dm644 ${m.appId}.desktop $desktopDest',
      if (m.icon != null)
        'install -Dm644 icon${p.extension(m.icon!.path)} $iconDest',
      for (final e in extras) 'install -Dm644 ${e.staged} ${e.dest}',
    ];
    final b = StringBuffer()
      ..writeln('app-id: ${m.appId}')
      ..writeln('runtime: ${m.runtime}')
      ..writeln("runtime-version: '${m.runtimeVersion}'")
      ..writeln('sdk: ${m.sdk}')
      ..writeln('command: ${m.command}')
      ..writeln('finish-args:');
    for (final a in m.finishArgs) {
      b.writeln('  - $a');
    }
    b
      ..writeln('modules:')
      ..writeln('  - name: $desktopName')
      ..writeln('    buildsystem: simple')
      ..writeln('    build-commands:');
    for (final c in cmds) {
      b.writeln('      - $c');
    }
    b
      ..writeln('    sources:')
      ..writeln('      - type: dir')
      ..writeln('        path: .');
    return b.toString();
  }

  String _desktop(FlatpakMetadata m, String name) {
    final b = StringBuffer()
      ..writeln('[Desktop Entry]')
      ..writeln('Type=Application')
      ..writeln('Name=$name')
      ..writeln('Exec=${m.command}')
      ..writeln('Terminal=false')
      ..writeln('Categories=${m.categories.join(';')};');
    if (m.icon != null) b.writeln('Icon=${m.appId}');
    return b.toString();
  }

  /// Normalize an extra-file destination to an absolute `/app/...` path.
  String _appDest(String dest) {
    final rel = dest.startsWith('/') ? dest.substring(1) : dest;
    return p.posix.join('/app', rel);
  }

  String _iconExt(File? icon) {
    if (icon == null) return '.png';
    final ext = p.extension(icon.path).toLowerCase();
    // hicolor expects `.png` under the sized dir; SVGs belong elsewhere but we
    // keep the basename so at minimum the file is shipped.
    return ext.isEmpty ? '.png' : ext;
  }

  bool _looksLikeAppId(String id) =>
      RegExp(r'^[A-Za-z][\w-]*(\.[A-Za-z][\w-]*){2,}$').hasMatch(id);

  /// Locate [exe] on PATH (`command -v`), or null when absent.
  Future<String?> _which(String exe) async {
    final r = await _run('command', ['-v', exe], runInShell: true);
    if (r.exitCode != 0) return null;
    final out = '${r.stdout}'.trim();
    return out.isEmpty ? null : out;
  }

  /// Recursively copy [src] into [dst] via `cp -a` (preserves mode + symlinks).
  Future<void> _copyTree(Directory src, Directory dst) async {
    dst.createSync(recursive: true);
    final r = await _run('cp', [
      '-a',
      '.',
      dst.path,
    ], workingDirectory: src.path);
    if (r.exitCode != 0) {
      throw FlatpakPackageException('copy failed: ${r.stderr}');
    }
  }
}

/// A staged extra file and its destination inside `/app`.
class _Extra {
  _Extra(this.staged, this.dest);
  final String staged;
  final String dest;
}
