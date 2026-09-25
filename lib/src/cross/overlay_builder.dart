import 'dart:ffi';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:emb_cli/src/cross/build_jobs.dart';
import 'package:emb_cli/src/cross/cross_keys.dart'
    show augmentIdentity, contentHash;
import 'package:emb_cli/src/cross/cross_profile.dart';
import 'package:emb_cli/src/cross/cross_target.dart';
import 'package:emb_cli/src/cross/process_runner.dart';
import 'package:emb_cli/src/cross/toolchain_emitter.dart';
import 'package:emb_cli/src/repo/patch_series.dart';
import 'package:emb_cli/src/step_reporter.dart';
import 'package:emb_cli/src/workspace/workspace.dart';
import 'package:mason_logger/mason_logger.dart';
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

enum _OverlayDownloadResult {
  success,
  missingFile,
  fsError,
  invalidTarball,
  invalidArchive,
  failedOpen,
  invalidSha,
}

const Map<_OverlayDownloadResult, String> _overlayDownloadErrorMessage = {
  _OverlayDownloadResult.success: 'download successful!',
  _OverlayDownloadResult.missingFile: 'destination file missing',
  _OverlayDownloadResult.fsError: 'FileSystemException',
  _OverlayDownloadResult.invalidTarball: 'corrupt tarball',
  _OverlayDownloadResult.invalidArchive: 'not a valid archive',
  _OverlayDownloadResult.failedOpen: 'failed to decompress archive',
  _OverlayDownloadResult.invalidSha: 'sha256 signature is not valid',
};

// Maintainable enum of supported archive formats;
// For each type, its magic bytes, offset and probe cmd are listed.
// This makes adding the support of new archive formats trivial, as only
// this enum needs updating without further patching to any logic below.
enum _ArchiveType {
  // dart format off
  gzip    ([0x1f, 0x8b],                          0,   'gzip -t',),
  zip     ([0x50, 0x4b],                          0,   'unzip -t -q',),
  xz      ([0xfd, 0x37, 0x7a, 0x58, 0x5a, 0x00],  0,   'xz -t',),
  bzip2   ([0x42, 0x5a, 0x68],                    0,   'bzip2 -t',),
  zstd    ([0x28, 0xb5, 0x2f, 0xfd],              0,   'zstd -t',),
  // 'ustar' in ASCII bytes
  tar     ([0x75, 0x73, 0x74, 0x61, 0x72],        257, 'tar -tf',);
  // dart format on

  const _ArchiveType(this.magicBytes, this.magicOffset, this.probeCmd);

  final List<int> magicBytes;
  final int magicOffset;
  final String probeCmd;
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
    Directory? sourceCacheDir,
    Logger? logger,
  }) : _emitter = emitter,
       _run = runProcess,
       _http = httpClient ?? HttpClient(),
       _launcher = launcher,
       _sourceCacheDir = sourceCacheDir,
       _steps = logger == null ? null : StepReporter(logger);

  final Workspace workspace;
  final CrossProfile profile;
  final ToolchainEmitter _emitter;
  final ProcessRunner _run;
  final HttpClient _http;

  /// Compiler-cache launcher (`ccache`/`sccache`), already resolved on `PATH`,
  /// or null. Applied to the augment CMake builds as a compiler launcher, but
  /// not the host-tool builds (those use the host compiler).
  final String? _launcher;

  /// Project root whose `.cache/overlay-src` holds fetched augment tarballs —
  /// isolating sources per project rather than sharing them in the workspace.
  /// When unset, falls back to today's shared `<workspace>/overlay-src`.
  final Directory? _sourceCacheDir;

  /// Spinner/banners for long steps (per-lib augment fetches + builds). Null
  /// when no logger was injected — keeps unit tests free of console output.
  final StepReporter? _steps;

  String? _cachedCompilerVersions;

  /// Format a byte count as e.g. `12.3 MB`, matching `_human` style used by
  /// other emb commands (`cross_command.dart`).
  static String _bytes(int n) {
    const units = ['B', 'KB', 'MB', 'GB'];
    var v = n.toDouble();
    var i = 0;
    while (v >= 1024 && i < units.length - 1) {
      v /= 1024;
      i++;
    }
    return '${v.toStringAsFixed(i == 0 || v >= 100 ? 0 : 1)} ${units[i]}';
  }

  /// First line of `$CC --version` and `$CXX --version`, joined, used to key
  /// host-tool stamps so a compiler upgrade invalidates the cached binary.
  /// Strips ccache/sccache wrappers so `CC="ccache gcc"` resolves to `gcc`.
  /// Empty string per tool on any failure so a missing compiler doesn't break.
  Future<String> _compilerVersions() async {
    if (_cachedCompilerVersions != null) return _cachedCompilerVersions!;
    Future<String> probe(String envVar, String fallback) async {
      const wrappers = {'ccache', 'sccache'};
      final parts = (Platform.environment[envVar] ?? fallback).trim().split(
        RegExp(r'\s+'),
      );
      final exe = parts.firstWhere(
        (p) => !wrappers.contains(p),
        orElse: () => fallback,
      );
      try {
        final r = await _run(exe, ['--version']);
        return r.stdout.split('\n').first.trim();
      } on ProcessException {
        return '';
      }
    }

    final results = await Future.wait([probe('CC', 'cc'), probe('CXX', 'c++')]);
    _cachedCompilerVersions = results.join('|');
    return _cachedCompilerVersions!;
  }

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
        final onStep = _steps?.start('augment ${lib.pkg}');
        try {
          final hostBin = await _buildHostTool(lib, onStep: onStep);
          if (!binDirs.contains(hostBin)) binDirs.add(hostBin);
          onStep?.complete('${lib.pkg} host built → $hostBin');
        } catch (e) {
          onStep?.fail(e is OverlayBuildException ? e.message : '$e');
          rethrow;
        }
        continue;
      }

      // Start the spinner *before* the sysroot probe so a slow pkg-config
      // check doesn't leave silence between libs. If satisfied, complete it as
      // "cached"; otherwise run fetch+build and update/complete along the way.
      final onStep = _steps?.start('augment ${lib.pkg}');

      // A local augment is always built: the developer is editing that tree,
      // and a previously installed copy satisfying `min` is exactly when the
      // edit under way would be skipped. See AugmentLib.path.
      try {
        if (!lib.isLocal && !await _satisfied(lib)) {
          switch (lib.build) {
            case CrossGenerator.meson:
              await _buildMeson(lib, overlay, onStep: onStep);
            case CrossGenerator.cmake:
              await _buildCMake(lib, overlay, onStep: onStep);
          }
          onStep?.complete(
            '${lib.pkg}: installed to ${overlay.path}', //
          );
        } else {
          onStep?.complete(
            '${lib.pkg}: cached (sysroot satisfies ${lib.minVersion})',
          );
        }
      } catch (e) {
        onStep?.fail(e is OverlayBuildException ? e.message : '$e');
        rethrow;
      }
      continue;
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

  /// A fresh build dir for [lib]'s source — wiped first so a re-run never
  /// reuses a stale (possibly mis-configured) meson/cmake cache.
  ///
  /// For a downloaded tarball that is `_build/` inside the unpacked tree, which
  /// emb owns and re-unpacks at will. A local tree belongs to the developer, so
  /// its build dir goes in the workspace instead: emb creates and deletes this
  /// directory on every run, which is not something to do inside someone's
  /// checkout.
  Directory _freshBuildDir(AugmentLib lib, Directory src) {
    final bld = lib.isLocal
        ? Directory(
            p.join(
              workspace.ensurePlatformDir('overlay-build').path,
              '${lib.pkg}-local',
            ),
          )
        : Directory(p.join(src.path, '_build'));
    if (bld.existsSync()) bld.deleteSync(recursive: true);
    return bld..createSync(recursive: true);
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

  /// Where fetched augment tarballs + unpacked trees live. Project-local when a
  /// sourceCacheDir was passed (so projects don't collide on the shared
  /// workspace dir), else the legacy workspace `overlay-src` location.
  Directory _overlaySrcDir() {
    final root = _sourceCacheDir;
    if (root == null) return workspace.ensurePlatformDir('overlay-src');
    return Directory(p.join(root.path, '.cache', 'overlay-src'))
      ..createSync(recursive: true);
  }

  /// Whether [tarball] is a usable archive: recognized magic bytes, passing
  /// an integrity test (`gzip -t` / `unzip -t`), and — when the manifest pins
  /// a [sha] — a matching sha256. A cached download can be truncated (an
  /// interrupted fetch, a disk-full write) or hold an HTML error page saved
  /// under a tarball name; trusting `existsSync()` alone lets those through,
  /// and the failure only surfaces later as a misleading patch error against
  /// an empty tree. Anything failing here is deleted so the caller
  /// re-downloads.
  Future<_OverlayDownloadResult> _validateArchive(
    File tarball,
    String? sha,
  ) async {
    // Check 0: is the file present?
    if (!tarball.existsSync()) {
      return _OverlayDownloadResult.missingFile;
    }

    // Check 1: is SHA256 valid?
    final expected = sha?.toLowerCase();
    final actual = await _sha256(tarball);
    if (expected != null && actual != expected) {
      return _OverlayDownloadResult.invalidSha;
    }

    // Check 2: are the magic bytes valid for archive type? A format may pin
    // its magic at a nonzero offset (tar's 'ustar' sits at 257), so read a
    // window wide enough to cover the deepest one and compare per-type.
    final magicWindow = _ArchiveType
        .values //
        .map((e) => e.magicOffset + e.magicBytes.length)
        .reduce(max);

    final magic = Uint8List(magicWindow);
    try {
      final raf = await tarball.open();
      try {
        final n = await raf.readInto(magic, 0, magicWindow);
        if (n < 2) {
          return _OverlayDownloadResult.invalidTarball;
        }
      } finally {
        await raf.close();
      }
    } on FileSystemException {
      return _OverlayDownloadResult.fsError;
    }

    _ArchiveType? archiveType;
    for (final type in _ArchiveType.values) {
      // Shorter than the type's magic even at its offset: can't match.
      if (magic.length < type.magicOffset + type.magicBytes.length) {
        continue;
      }
      var validForType = true;
      for (var i = 0; i < type.magicBytes.length; i++) {
        if (magic[type.magicOffset + i] != type.magicBytes[i]) {
          validForType = false;
          break;
        }
      }

      if (validForType) {
        archiveType = type;
        break;
      }
    }

    if (archiveType == null) {
      return _OverlayDownloadResult.invalidArchive;
    }

    // Check 3: does the file open?
    final probe = archiveType.probeCmd.split(' ');
    final test = await _run(probe[0], [...(probe.sublist(1)), tarball.path]);
    if (test.exitCode != 0) {
      return _OverlayDownloadResult.failedOpen;
    }

    return _OverlayDownloadResult.success;
  }

  Future<Directory> _fetchSource(AugmentLib lib, {StepHandle? onStep}) async {
    // A local tree is the source: nothing to download, nothing to unpack, and
    // nothing to patch (CrossTarget rejects `patches:` with `path:`, because
    // applying them would rewrite files emb did not create).
    if (lib.isLocal) {
      final dir = Directory(lib.path!);
      if (!dir.existsSync()) {
        throw OverlayBuildException(
          '${lib.pkg}: path "${lib.path}" does not exist',
        );
      }
      return dir;
    }

    final src = _overlaySrcDir();
    // Prefix the package name so two augments whose URLs share a basename
    // (e.g. two vendors both publishing `v1.0.0.tar.gz`) can't collide on,
    // and then cross-validate, the same cached tarball.
    final tarball = File(
      p.join(src.path, '${lib.pkg}-${p.basename(Uri.parse(lib.url).path)}'),
    );

    // Retry downloading: a sha-pinned source whose bytes don't match the
    // pin is deleted and re-fetched once (an upstream mirror swap or a
    // half-written body recover cleanly), and the last mismatch is a real
    // manifest/upstream divergence that must fail loudly, not loop. The final
    // "fetched" label stays on this handle until the caller completes/fails it
    // — StepHandle.complete() may only be called once per spinner.
    const maxRetries = 3;
    late _OverlayDownloadResult? result;

    for (var downloadAttempts = 0; ; downloadAttempts++) {
      // Check previous attempt
      if (tarball.existsSync()) {
        // If tarball is valid, skip download
        result = await _validateArchive(tarball, lib.sha256);

        if (result == _OverlayDownloadResult.success) {
          // A usable archive was already in the cache before we tried to fetch.
          if (downloadAttempts == 0) {
            onStep?.update(
              '${lib.pkg} (${_bytes(tarball.lengthSync())}, cached)',
            );
          } else {
            final size = tarball.lengthSync();
            onStep?.update('${lib.pkg} fetched (${_bytes(size)})');
          }
          break;
        }
        // If there was a previous failed download attempt, delete it
        else {
          await tarball.delete();
        }
      }

      // If maxRetries exceeded, fail loudly
      if (downloadAttempts == maxRetries) {
        throw OverlayBuildException(
          '${lib.pkg}: download failed $maxRetries retries (${lib.url})\n'
          'Last error: ${_overlayDownloadErrorMessage[result]}',
        );
      }

      // Try downloading
      onStep?.update(
        'Downloading ${lib.pkg} (attempt ${downloadAttempts + 1}/$maxRetries)',
      );
      try {
        await _download(lib.url, tarball);
      } catch (e) {
        // `_download` retries transient failures internally; reaching here
        // means a hard error. Propagate so `build()`'s handler fails the
        // spinner with this message instead of leaving it spinning
        rethrow;
      }
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
    // The stamp is written even when there are no patches (empty digest), so a
    // directory only survives reuse when this code created it — stale trees
    // from older runs or hand-made dirs carry no stamp, mismatch the current
    // series, and get re-unpacked; without that guard a no-patch augment could
    // silently reuse an empty foreign dir (the original bug we are fixing).
    final patches = lib.patches;
    final digest = patches.isEmpty ? '' : patchSeriesDigest(patches);
    final stamp = File(p.join(dir.path, '.emb-patch-stamp'));
    if (dir.existsSync()) {
      // Reuse is only safe when this code wrote the tree: a matching
      // `.emb-patch-stamp` proves it. Anything else — an absent dir, a
      // missing stamp, or a stale digest from before patches were added/edited
      // — gets wiped so we re-unpack clean rather than silently reuse it.
      if (!stamp.existsSync()) {
        dir.deleteSync(recursive: true);
      } else {
        final stamped = stamp.readAsStringSync().trim();
        if (stamped != digest) dir.deleteSync(recursive: true);
      }
    }

    if (!dir.existsSync()) {
      onStep?.update('Extracting ${lib.pkg}…');
      // Extract into a staging dir and promote it only on success, so a
      // failing extraction (corrupt tarball, `tar` exit != 0) can never leave
      // a pre-created empty [dir] behind for the next run to reuse — that
      // hole is what turned a bad download into a misleading patch error
      // against an empty tree.
      final stage = Directory('${dir.path}.unzip');
      if (stage.existsSync()) stage.deleteSync(recursive: true);
      stage.createSync(recursive: true);
      final RunResult extracted;
      if (tarball.path.toLowerCase().endsWith('.zip')) {
        // GNU `tar` can't read a zip and `unzip` has no `--strip-components`,
        // so unzip into a staging dir and promote a lone top-level directory to
        // reproduce the tar path's `--strip-components=1`. Release zips that
        // bundle vendored subtrees (e.g. sentry-native's crashpad/breakpad) come
        // this way.
        extracted = await _run('unzip', ['-q', tarball.path, '-d', stage.path]);
      } else {
        extracted = await _run('tar', [
          '-xf',
          tarball.path,
          '-C',
          stage.path,
          '--strip-components=1',
        ]);
      }
      final detail = [
        extracted.stdout,
        extracted.stderr,
      ].map((s) => s.trim()).where((s) => s.isNotEmpty).join('\n');
      if (extracted.exitCode != 0) {
        stage.deleteSync(recursive: true);
        throw OverlayBuildException(
          '${lib.pkg}: extract failed (exit ${extracted.exitCode}) '
          'from ${tarball.path}'
          '${detail.isEmpty ? '' : '\n$detail'}',
        );
      }
      if (stage.listSync().isEmpty) {
        // Exit 0 on an empty archive (e.g. a stub tarball) would otherwise
        // produce an empty source tree that "builds" into nothing.
        stage.deleteSync(recursive: true);
        throw OverlayBuildException(
          '${lib.pkg}: extract produced no files from ${tarball.path}'
          '${detail.isEmpty ? '' : '\n$detail'}',
        );
      }
      if (tarball.path.toLowerCase().endsWith('.zip')) {
        final top = stage.listSync();
        if (top.length == 1 && top.single is Directory) {
          (top.single as Directory).renameSync(dir.path);
          stage.deleteSync(recursive: true);
        } else {
          stage.renameSync(dir.path);
        }
      } else {
        stage.renameSync(dir.path);
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
      }
      stamp.writeAsStringSync(digest);
    }
    return dir;
  }

  Future<void> _buildMeson(
    AugmentLib lib,
    Directory overlay, {
    StepHandle? onStep,
  }) async {
    final src = await _fetchSource(lib, onStep: onStep);
    final bld = _freshBuildDir(lib, src);
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
    onStep?.update('${lib.pkg}: meson setup');
    _check(lib, 'meson setup', setup);
    onStep?.update('${lib.pkg}: building (ninja)');
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

  Future<void> _buildCMake(
    AugmentLib lib,
    Directory overlay, {
    StepHandle? onStep,
  }) async {
    final src = await _fetchSource(lib, onStep: onStep);
    // Configure a subtree when the augment asks for one (patches still applied
    // against the unpacked root by _fetchSource). Lets a repository whose root
    // builds a whole app expose a self-contained library under a subdir.
    final sub = lib.subdir;
    final srcDir = sub == null || sub.isEmpty
        ? src.path
        : p.join(src.path, sub);
    final bld = _freshBuildDir(lib, src);
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
    onStep?.update('${lib.pkg}: cmake configure');
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
  /// A stamp keyed on [augmentIdentity] plus host OS, arch, and compiler
  /// versions skips the build when the inputs haven't changed — host tools are
  /// otherwise rebuilt on every `--build` because `_freshBuildDir` wipes the
  /// cmake dir. The stamp is deleted before each build so a failed install
  /// doesn't leave a stale hit; the payload dir is also checked so a partial
  /// prune falls through to a rebuild rather than returning a bad path.
  Future<String> _buildHostTool(AugmentLib lib, {StepHandle? onStep}) async {
    final hostTools = workspace.ensurePlatformDir('host-tools');
    final toolDir = Directory(p.join(hostTools.path, lib.pkg))
      ..createSync(recursive: true);
    final stampFile = File(p.join(toolDir.path, 'stamp'));
    final key = await _hostToolKey(lib);
    final binDir = p.join(toolDir.path, 'usr', 'bin');
    if (stampFile.existsSync() &&
        stampFile.readAsStringSync().trim() == key &&
        Directory(binDir).existsSync()) {
      return binDir;
    }
    if (stampFile.existsSync()) stampFile.deleteSync();
    final bin = await switch (lib.build) {
      CrossGenerator.cmake => _buildCMakeHost(lib, toolDir, onStep: onStep),
      CrossGenerator.meson => _buildMesonHost(lib, toolDir, onStep: onStep),
    };
    Directory(bin).createSync(recursive: true);
    stampFile.writeAsStringSync(key);
    return bin;
  }

  Future<String> _hostToolKey(AugmentLib lib) async => contentHash([
    augmentIdentity(lib),
    Platform.operatingSystem,
    Abi.current().toString(),
    await _compilerVersions(),
  ]);

  Future<String> _buildCMakeHost(
    AugmentLib lib,
    Directory toolDir, {
    StepHandle? onStep,
  }) async {
    final src = await _fetchSource(lib, onStep: onStep);
    final bld = _freshBuildDir(lib, src);
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
    onStep?.update('${lib.pkg}: cmake configure');
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
        environment: {'DESTDIR': toolDir.path},
        output: ProcessOutputMode.stream,
      ),
    );
    return p.join(toolDir.path, 'usr', 'bin');
  }

  Future<String> _buildMesonHost(
    AugmentLib lib,
    Directory toolDir, {
    StepHandle? onStep,
  }) async {
    final src = await _fetchSource(lib, onStep: onStep);
    final bld = _freshBuildDir(lib, src);
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
    onStep?.update('${lib.pkg}: meson setup');
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
        environment: {'DESTDIR': toolDir.path},
        output: ProcessOutputMode.stream,
      ),
    );
    return p.join(toolDir.path, 'usr', 'bin');
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
    // Write to a `.part` file and rename into place only on success, so an
    // interrupted fetch (Ctrl-C, kill, disk-full) can never leave a truncated
    // body at [dest] for the next run to trust as a complete download.
    const maxAttempts = 4;
    final part = File('${dest.path}.part');
    for (var attempt = 1; ; attempt++) {
      try {
        final req = await _http.getUrl(Uri.parse(url));
        req.followRedirects = true;
        final resp = await req.close();
        if (resp.statusCode == 200) {
          if (part.existsSync()) part.deleteSync();
          await resp.pipe(part.openWrite());
          part.renameSync(dest.path);
          return;
        }
        await resp.drain<void>();
        final transient = resp.statusCode >= 500 || resp.statusCode == 429;
        if (!transient || attempt == maxAttempts) {
          if (part.existsSync()) part.deleteSync();
          throw OverlayBuildException(
            'download failed ($url): ${resp.statusCode}',
          );
        }
      } on IOException catch (e) {
        if (part.existsSync()) part.deleteSync();
        if (attempt == maxAttempts) {
          throw OverlayBuildException('download failed ($url): $e');
        }
      }
      await Future<void>.delayed(Duration(seconds: attempt * 2));
    }
  }

  /// Close the underlying HTTP client.
  void close() => _http.close(force: true);

  Future<String> _sha256(File f) async {
    final digest = await sha256.bind(f.openRead()).first;
    return digest.toString();
  }
}

/// Thrown when an augment library fails to build into the overlay.
class OverlayBuildException implements Exception {
  OverlayBuildException(this.message);
  final String message;
  @override
  String toString() => 'OverlayBuildException: $message';
}
