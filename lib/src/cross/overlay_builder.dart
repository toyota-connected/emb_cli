import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:emb_cli/src/cross/cross_profile.dart';
import 'package:emb_cli/src/cross/cross_target.dart';
import 'package:emb_cli/src/cross/process_runner.dart';
import 'package:emb_cli/src/cross/toolchain_emitter.dart';
import 'package:emb_cli/src/workspace/workspace.dart';
import 'package:path/path.dart' as p;

/// The include/lib/pkg-config search dirs an overlay contributes. The build
/// stage prepends these to the sysroot's so the freshly-built libs win.
class OverlayPaths {
  const OverlayPaths({
    required this.prefix,
    required this.includeDirs,
    required this.libDirs,
    required this.pkgConfigDirs,
  });

  final String prefix;
  final List<String> includeDirs;
  final List<String> libDirs;
  final List<String> pkgConfigDirs;

  /// pkg-config env that searches the overlay first, then the sysroot.
  Map<String, String> pkgConfigEnv(CrossProfile profile) {
    final base = profile.pkgConfig?.libdir ?? const [];
    return {
      'PKG_CONFIG_LIBDIR': [...pkgConfigDirs, ...base].join(':'),
      if (profile.pkgConfig != null)
        'PKG_CONFIG_SYSROOT_DIR': profile.pkgConfig!.sysrootDir,
    };
  }
}

/// Builds [CrossTarget.augment] libraries (libdisplay-info, Vulkan-Headers, …)
/// from source into a per-workspace overlay prefix, against an already-resolved
/// [CrossProfile].
///
/// Generalizes the scripts' local deps (`*_local_display_info` /
/// `*_local_vulkan_headers`): each lib is skipped when the sysroot already
/// satisfies its `min` version, else fetched, configured against the profile's
/// toolchain, and installed with `DESTDIR=<overlay>` — never into the
/// (possibly shared / read-only) sysroot. This is the key divergence from the
/// scripts, which install straight into the sysroot.
class OverlayBuilder {
  OverlayBuilder(
    this.workspace,
    this.profile, {
    ToolchainEmitter emitter = const ToolchainEmitter(),
    ProcessRunner runProcess = defaultProcessRunner,
    HttpClient? httpClient,
  }) : _emitter = emitter,
       _run = runProcess,
       _http = httpClient ?? HttpClient();

  final Workspace workspace;
  final CrossProfile profile;
  final ToolchainEmitter _emitter;
  final ProcessRunner _run;
  final HttpClient _http;

  /// Build every lib in [libs] that the sysroot doesn't already satisfy.
  /// Returns the overlay search paths to layer onto the build env.
  ///
  /// When [stageInto] is given the libs install under `<stageInto>/usr`
  /// instead of a separate overlay prefix — used to stage an augment straight
  /// into a private, regenerable sysroot so pkg-config finds it with the
  /// sysroot's own search env (no second `PKG_CONFIG_SYSROOT_DIR`).
  Future<OverlayPaths> build(
    List<AugmentLib> libs, {
    Directory? stageInto,
  }) async {
    final overlay =
        stageInto ??
        workspace.ensurePlatformDir('overlay-${profile.targetTriple}');
    final usr = p.join(overlay.path, 'usr');
    final paths = OverlayPaths(
      prefix: overlay.path,
      includeDirs: [p.join(usr, 'include')],
      libDirs: [p.join(usr, 'lib')],
      pkgConfigDirs: [
        p.join(usr, 'lib', 'pkgconfig'),
        p.join(usr, 'share', 'pkgconfig'),
      ],
    );

    for (final lib in libs) {
      if (await _satisfied(lib)) continue;
      final ok = switch (lib.build) {
        CrossGenerator.meson => await _buildMeson(lib, overlay),
        CrossGenerator.cmake => await _buildCMake(lib, overlay),
      };
      if (!ok) {
        throw OverlayBuildException('failed to build ${lib.pkg} into overlay');
      }
    }
    return paths;
  }

  /// True when the sysroot already provides [lib] at >= its `min` version.
  Future<bool> _satisfied(AugmentLib lib) async {
    final sysroot = profile.pkgConfig?.sysrootDir ?? profile.targetSysroot;
    final r = await _run(
      'pkg-config',
      ['--atleast-version=${lib.minVersion}', lib.pkg],
      environment: {
        'PKG_CONFIG_LIBDIR': (profile.pkgConfig?.libdir ?? const []).join(':'),
        'PKG_CONFIG_SYSROOT_DIR': sysroot,
      },
    );
    return r.exitCode == 0;
  }

  Future<Directory> _fetchSource(AugmentLib lib) async {
    final src = workspace.ensurePlatformDir('overlay-src');
    final tarball = File(p.join(src.path, p.basename(Uri.parse(lib.url).path)));
    if (!tarball.existsSync()) {
      await _download(lib.url, tarball);
    }
    final dir = Directory(p.join(src.path, '${lib.pkg}-${lib.minVersion}'));
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
      await _run('tar', [
        '-xf',
        tarball.path,
        '-C',
        dir.path,
        '--strip-components=1',
      ]);
    }
    return dir;
  }

  Future<bool> _buildMeson(AugmentLib lib, Directory overlay) async {
    final src = await _fetchSource(lib);
    final bld = Directory(p.join(src.path, '_build'))..createSync();
    // Prefer the profile's meson cross file; else emit one from its fields.
    final cross =
        profile.mesonCrossFile ??
        _emitter.emitMeson(
          outDir: workspace.ensurePlatformDir('cross-${profile.targetTriple}'),
          triple: profile.targetTriple,
          crossBin: p.dirname(profile.cc),
          sysroot: profile.targetSysroot,
          cpuFlags: profile.cFlags,
        );
    final setup = await _run('meson', [
      'setup',
      bld.path,
      src.path,
      '--cross-file',
      cross,
      '--prefix',
      '/usr',
      '--libdir',
      'lib',
      '--buildtype',
      'release',
      '--default-library',
      if (lib.staticLink) 'static' else 'shared',
    ], environment: profile.buildEnv());
    if (setup.exitCode != 0) return false;
    if ((await _run('ninja', ['-C', bld.path])).exitCode != 0) return false;
    final install = await _run(
      'ninja',
      ['-C', bld.path, 'install'],
      environment: {...profile.buildEnv(), 'DESTDIR': overlay.path},
    );
    return install.exitCode == 0;
  }

  Future<bool> _buildCMake(AugmentLib lib, Directory overlay) async {
    final src = await _fetchSource(lib);
    final bld = Directory(p.join(src.path, '_build'))..createSync();
    final tc = profile.cmakeToolchainFile;
    final configure = await _run('cmake', [
      '-S',
      src.path,
      '-B',
      bld.path,
      if (tc != null) '-DCMAKE_TOOLCHAIN_FILE=$tc',
      '-DCMAKE_INSTALL_PREFIX=/usr',
      '-DCMAKE_BUILD_TYPE=Release',
    ], environment: profile.buildEnv());
    if (configure.exitCode != 0) return false;
    // Header-only (e.g. Vulkan-Headers) installs with no build step.
    final install = await _run('cmake', [
      '--install',
      bld.path,
      '--prefix',
      p.join(overlay.path, 'usr'),
    ], environment: profile.buildEnv());
    return install.exitCode == 0;
  }

  Future<void> _download(String url, File dest) async {
    final req = await _http.getUrl(Uri.parse(url));
    req.followRedirects = true;
    final resp = await req.close();
    if (resp.statusCode != 200) {
      await resp.drain<void>();
      throw OverlayBuildException('download failed ($url): ${resp.statusCode}');
    }
    await resp.pipe(dest.openWrite());
  }

  /// Close the underlying HTTP client.
  void close() => _http.close(force: true);

  // Retained for sha-pinned augment sources (parity with EngineArtifacts).
  // ignore: unused_element
  String _sha256(File f) => sha256.convert(f.readAsBytesSync()).toString();
}

/// Thrown when an augment library fails to build into the overlay.
class OverlayBuildException implements Exception {
  OverlayBuildException(this.message);
  final String message;
  @override
  String toString() => 'OverlayBuildException: $message';
}
