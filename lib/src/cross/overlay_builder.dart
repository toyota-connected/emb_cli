import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:emb_cli/src/cross/build_jobs.dart';
import 'package:emb_cli/src/cross/cross_keys.dart' show contentHash;
import 'package:emb_cli/src/cross/cross_profile.dart';
import 'package:emb_cli/src/cross/cross_target.dart';
import 'package:emb_cli/src/cross/process_runner.dart';
import 'package:emb_cli/src/cross/toolchain_emitter.dart';
import 'package:emb_cli/src/repo/patch_series.dart';
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
    this.binDirs = const [],
  });

  final String prefix;
  final List<String> includeDirs;
  final List<String> libDirs;
  final List<String> pkgConfigDirs;

  /// Host-tool bin dirs (from `host: true` augments) to prepend to the cross
  /// build's PATH so its `find_program` resolves a build-machine binary.
  final List<String> binDirs;

  /// pkg-config env that searches the overlay first, then the sysroot.
  Map<String, String> pkgConfigEnv(CrossProfile profile) {
    final pc = profile.pkgConfig;
    // Native build (no sysroot): PREPEND the overlay via PKG_CONFIG_PATH so the
    // host's default search path — and its system packages (xkbcommon, …) —
    // still resolve. PKG_CONFIG_LIBDIR would REPLACE that default and hide the
    // host, which only makes sense for a cross build isolating against a
    // sysroot.
    if (pc == null) {
      return {'PKG_CONFIG_PATH': pkgConfigDirs.join(':')};
    }
    return {
      'PKG_CONFIG_LIBDIR': [...pkgConfigDirs, ...pc.libdir].join(':'),
      'PKG_CONFIG_SYSROOT_DIR': pc.sysrootDir,
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
    String? launcher,
  }) : _emitter = emitter,
       _run = runProcess,
       _http = httpClient ?? HttpClient(),
       _launcher = launcher;

  final Workspace workspace;
  final CrossProfile profile;
  final ToolchainEmitter _emitter;
  final ProcessRunner _run;
  final HttpClient _http;

  /// Compiler-cache launcher (`ccache`/`sccache`), already resolved on `PATH`,
  /// or null. Applied to the augment CMake builds as a compiler launcher, but
  /// not the host-tool builds (those use the host compiler).
  final String? _launcher;

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
    final binDirs = <String>[];

    for (final lib in libs) {
      // Host tools (e.g. a code generator the cross build runs via
      // find_program) are built with the host toolchain and exposed on PATH,
      // not cross-compiled into the sysroot. They have no pkg-config presence,
      // so skip the sysroot satisfied check.
      if (lib.host) {
        final hostBin = await _buildHostTool(lib);
        if (!binDirs.contains(hostBin)) binDirs.add(hostBin);
        continue;
      }
      if (await _satisfied(lib)) continue;
      switch (lib.build) {
        case CrossGenerator.meson:
          await _buildMeson(lib, overlay);
        case CrossGenerator.cmake:
          await _buildCMake(lib, overlay);
      }
    }
    return OverlayPaths(
      prefix: overlay.path,
      includeDirs: [p.join(usr, 'include')],
      libDirs: [p.join(usr, 'lib')],
      pkgConfigDirs: [
        p.join(usr, 'lib', 'pkgconfig'),
        p.join(usr, 'share', 'pkgconfig'),
      ],
      binDirs: binDirs,
    );
  }

  /// A fresh build dir for [src] — wiped first so a re-run never reuses a stale
  /// (possibly mis-configured) meson/cmake cache.
  Directory _freshBuildDir(Directory src) {
    final bld = Directory(p.join(src.path, '_build'));
    if (bld.existsSync()) bld.deleteSync(recursive: true);
    return bld..createSync();
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

    // An unpacked tree is reused as-is, which stays correct only while the
    // patch series that shaped it is unchanged. Neither `url` nor `min` moves
    // when a patch is edited in place, so stamp the tree with a digest of the
    // series and re-unpack when it no longer matches -- otherwise an edited
    // patch would silently have no effect on the next build.
    // Already absolute: CrossTarget.withResolvedPatches rebases them against
    // the declaring manifest at load, so the paths hashed into the cache keys
    // and the paths applied here are the same files.
    final patches = lib.patches;
    final digest = patches.isEmpty ? '' : patchSeriesDigest(patches);
    final stamp = File(p.join(dir.path, '.emb-patch-stamp'));
    if (dir.existsSync() && patches.isNotEmpty) {
      final stamped = stamp.existsSync() ? stamp.readAsStringSync().trim() : '';
      if (stamped != digest) dir.deleteSync(recursive: true);
    }

    if (!dir.existsSync()) {
      if (tarball.path.toLowerCase().endsWith('.zip')) {
        // GNU `tar` can't read a zip and `unzip` has no `--strip-components`,
        // so unzip into a staging dir and promote a lone top-level directory to
        // reproduce the tar path's `--strip-components=1`. Release zips that
        // bundle vendored subtrees (e.g. sentry-native's crashpad/breakpad) come
        // this way.
        final stage = Directory('${dir.path}.unzip');
        if (stage.existsSync()) stage.deleteSync(recursive: true);
        stage.createSync(recursive: true);
        await _run('unzip', ['-q', tarball.path, '-d', stage.path]);
        final top = stage.listSync();
        if (top.length == 1 && top.single is Directory) {
          (top.single as Directory).renameSync(dir.path);
          stage.deleteSync(recursive: true);
        } else {
          stage.renameSync(dir.path);
        }
      } else {
        dir.createSync(recursive: true);
        await _run('tar', [
          '-xf',
          tarball.path,
          '-C',
          dir.path,
          '--strip-components=1',
        ]);
      }

      // Patch the freshly unpacked tree, then stamp it. On failure the tree is
      // removed so the next run unpacks clean rather than reusing a partially
      // patched source -- which would still build, silently producing
      // something that does not match the manifest.
      if (patches.isNotEmpty) {
        try {
          await applyPatchSeries(
            runner: (args, {required workingDirectory}) =>
                Process.run('git', args, workingDirectory: workingDirectory),
            workDir: dir.path,
            patches: patches,
            onto: '${lib.pkg} ${lib.minVersion}',
            restore: () async {
              if (dir.existsSync()) dir.deleteSync(recursive: true);
            },
          );
        } on PatchSeriesException catch (e) {
          // Convert at the source rather than at each call site: a manifest
          // error must read as a reported failure, not as an uncaught
          // exception with a stack trace. Mirrors how GitRepo converts it for
          // `sync`, and keeps every OverlayBuilder caller consistent.
          throw OverlayBuildException('${lib.pkg}: ${e.message}');
        }
        stamp.writeAsStringSync(digest);
      }
    }
    return dir;
  }

  Future<void> _buildMeson(AugmentLib lib, Directory overlay) async {
    final src = await _fetchSource(lib);
    final bld = _freshBuildDir(src);
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
    final setup = await _run(
      'meson',
      [
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
        // Package-specific project options, mirroring the CMake path's cache
        // entries (e.g. `-Dsome_feature=enabled`). Meson uses the same
        // `-Dkey=value` syntax for project options.
        for (final e in lib.defines.entries) '-D${e.key}=${e.value}',
      ],
      environment: profile.buildEnv(),
      output: ProcessOutputMode.stream,
    );
    _check(lib, 'meson setup', setup);
    _check(
      lib,
      'ninja',
      await _run('ninja', ['-C', bld.path], output: ProcessOutputMode.stream),
    );
    _check(
      lib,
      'ninja install',
      await _run(
        'ninja',
        ['-C', bld.path, 'install'],
        environment: {...profile.buildEnv(), 'DESTDIR': overlay.path},
        output: ProcessOutputMode.stream,
      ),
    );
  }

  Future<void> _buildCMake(AugmentLib lib, Directory overlay) async {
    final src = await _fetchSource(lib);
    // Configure a subtree when the augment asks for one (patches still applied
    // against the unpacked root by _fetchSource). Lets a repository whose root
    // builds a whole app expose a self-contained library under a subdir.
    final sub = lib.subdir;
    final srcDir = sub == null || sub.isEmpty
        ? src.path
        : p.join(src.path, sub);
    final bld = _freshBuildDir(src);
    final tc = profile.cmakeToolchainFile;
    final configure = await _run(
      'cmake',
      [
        '-S',
        srcDir,
        '-B',
        bld.path,
        if (tc != null) '-DCMAKE_TOOLCHAIN_FILE=$tc',
        '-DCMAKE_INSTALL_PREFIX=/usr',
        '-DCMAKE_BUILD_TYPE=Release',
        if (_launcher != null) ...[
          '-DCMAKE_C_COMPILER_LAUNCHER=$_launcher',
          '-DCMAKE_CXX_COMPILER_LAUNCHER=$_launcher',
        ],
        // Honor the augment's `static` flag for libraries that defer to
        // BUILD_SHARED_LIBS (no explicit STATIC/SHARED on add_library).
        '-DBUILD_SHARED_LIBS=${lib.staticLink ? 'OFF' : 'ON'}',
        // Package-specific cache entries (e.g. BLEND2D_STATIC / BLEND2D_NO_JIT).
        for (final e in lib.defines.entries) '-D${e.key}=${e.value}',
      ],
      environment: profile.buildEnv(),
      output: ProcessOutputMode.stream,
    );
    _check(lib, 'cmake configure', configure);
    // Build before install. A no-op for header-only libs (e.g. Vulkan-Headers,
    // which expose no compiled targets), but required for compiled libs (e.g.
    // shadertoy-cxx): without it `cmake --install` has no built artifacts to
    // place and the install rule for a library target fails.
    _check(
      lib,
      'cmake build',
      await _run(
        'cmake',
        ['--build', bld.path, '--parallel', '${cmakeBuildJobs()}'],
        environment: profile.buildEnv(),
        output: ProcessOutputMode.stream,
      ),
    );
    // Stage via DESTDIR rather than `--install --prefix`: the configured
    // CMAKE_INSTALL_PREFIX (/usr) controls where files land and what gets baked
    // into configs/rpaths, while DESTDIR redirects the actual writes under the
    // overlay. DESTDIR prefixes every path (absolute install() rules included),
    // so the build never touches the host /usr and needs no sudo.
    _check(
      lib,
      'cmake install',
      await _run(
        'cmake',
        ['--install', bld.path],
        environment: {...profile.buildEnv(), 'DESTDIR': overlay.path},
        output: ProcessOutputMode.stream,
      ),
    );
  }

  /// Build a `host: true` augment with the **host** toolchain and install its
  /// executables under a shared `host-tools` prefix; returns the `bin` dir to
  /// prepend to the cross build's PATH. Deliberately passes no cross toolchain
  /// file and no `profile.buildEnv()` — the tool must run on the build machine,
  /// so it uses the host compiler and the inherited host environment.
  ///
  /// A stamp keyed on the lib's URL, version, defines, and patch digest skips
  /// the build when the inputs haven't changed — host tools are otherwise
  /// rebuilt on every `--build` because `_freshBuildDir` wipes the cmake dir.
  Future<String> _buildHostTool(AugmentLib lib) async {
    final hostTools = workspace.ensurePlatformDir('host-tools');
    final stampFile = File(p.join(hostTools.path, '${lib.pkg}.stamp'));
    final key = _hostToolKey(lib);
    if (stampFile.existsSync() &&
        stampFile.readAsStringSync().trim() == key) {
      return p.join(hostTools.path, 'usr', 'bin');
    }
    final bin = await switch (lib.build) {
      CrossGenerator.cmake => _buildCMakeHost(lib),
      CrossGenerator.meson => _buildMesonHost(lib),
    };
    stampFile.writeAsStringSync(key);
    return bin;
  }

  String _hostToolKey(AugmentLib lib) {
    final parts = [
      lib.url,
      lib.minVersion,
      lib.build.name,
      for (final e in (lib.defines.entries.toList()
        ..sort((a, b) => a.key.compareTo(b.key))))
        '${e.key}=${e.value}',
      if (lib.patches.isNotEmpty) patchSeriesDigest(lib.patches),
    ];
    return contentHash(parts);
  }

  Future<String> _buildCMakeHost(AugmentLib lib) async {
    final src = await _fetchSource(lib);
    final bld = _freshBuildDir(src);
    final hostTools = workspace.ensurePlatformDir('host-tools');
    _check(
      lib,
      'cmake configure (host)',
      await _run('cmake', [
        '-S',
        src.path,
        '-B',
        bld.path,
        '-DCMAKE_INSTALL_PREFIX=/usr',
        '-DCMAKE_BUILD_TYPE=Release',
        for (final e in lib.defines.entries) '-D${e.key}=${e.value}',
      ], output: ProcessOutputMode.stream),
    );
    _check(
      lib,
      'cmake build (host)',
      await _run('cmake', [
        '--build',
        bld.path,
        '--parallel',
        '${cmakeBuildJobs()}',
      ], output: ProcessOutputMode.stream),
    );
    _check(
      lib,
      'cmake install (host)',
      await _run(
        'cmake',
        ['--install', bld.path],
        environment: {'DESTDIR': hostTools.path},
        output: ProcessOutputMode.stream,
      ),
    );
    return p.join(hostTools.path, 'usr', 'bin');
  }

  Future<String> _buildMesonHost(AugmentLib lib) async {
    final src = await _fetchSource(lib);
    final bld = _freshBuildDir(src);
    final hostTools = workspace.ensurePlatformDir('host-tools');
    _check(
      lib,
      'meson setup (host)',
      await _run('meson', [
        'setup',
        bld.path,
        src.path,
        '--prefix',
        '/usr',
        '--libdir',
        'lib',
        '--buildtype',
        'release',
        for (final e in lib.defines.entries) '-D${e.key}=${e.value}',
      ], output: ProcessOutputMode.stream),
    );
    _check(
      lib,
      'ninja (host)',
      await _run('ninja', ['-C', bld.path], output: ProcessOutputMode.stream),
    );
    _check(
      lib,
      'ninja install (host)',
      await _run(
        'ninja',
        ['-C', bld.path, 'install'],
        environment: {'DESTDIR': hostTools.path},
        output: ProcessOutputMode.stream,
      ),
    );
    return p.join(hostTools.path, 'usr', 'bin');
  }

  /// Throw with the failing [step]'s stderr so an overlay failure is
  /// actionable rather than a bare "failed to build into overlay".
  void _check(AugmentLib lib, String step, RunResult r) {
    if (r.exitCode == 0) return;
    // meson/cmake write diagnostics to stdout as often as stderr, so surface
    // both — otherwise a "meson setup failed (exit 1)" is undebuggable.
    final detail = [
      r.stderr,
      r.stdout,
    ].map((s) => s.trim()).where((s) => s.isNotEmpty).join('\n');
    throw OverlayBuildException(
      '${lib.pkg}: $step failed (exit ${r.exitCode})'
      '${detail.isEmpty ? '' : '\n$detail'}',
    );
  }

  Future<void> _download(String url, File dest) async {
    // Retry transient failures (5xx / 429 / network) with backoff — a CI run
    // fetches augment sources on every job, so a single upstream hiccup (e.g.
    // a gitlab 500) shouldn't fail the build. 4xx and the like fail fast.
    const maxAttempts = 4;
    for (var attempt = 1; ; attempt++) {
      try {
        final req = await _http.getUrl(Uri.parse(url));
        req.followRedirects = true;
        final resp = await req.close();
        if (resp.statusCode == 200) {
          await resp.pipe(dest.openWrite());
          return;
        }
        await resp.drain<void>();
        final transient = resp.statusCode >= 500 || resp.statusCode == 429;
        if (!transient || attempt == maxAttempts) {
          throw OverlayBuildException(
            'download failed ($url): ${resp.statusCode}',
          );
        }
      } on IOException catch (e) {
        if (attempt == maxAttempts) {
          throw OverlayBuildException('download failed ($url): $e');
        }
      }
      await Future<void>.delayed(Duration(seconds: attempt * 2));
    }
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
