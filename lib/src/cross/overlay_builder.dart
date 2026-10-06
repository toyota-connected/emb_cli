import 'dart:ffi';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:emb_cli/src/cache/cache_lock.dart';
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

/// Outcome of validating a downloaded tarball. `fatal` marks the results a
/// re-download cannot fix: the bytes are not the problem, the environment is.
/// Everything else is a bad or half-written body, so the caller deletes the
/// file and fetches again.
enum _ValidationCode {
  success(fatal: false),
  missingFile(fatal: false),
  fsError(fatal: false),
  corruptArchive(fatal: false),
  // Neither the magic bytes nor the filename name a supported format. An HTML
  // error page, a rate-limit body or an auth redirect saved under a tarball
  // name looks exactly like this, and those *are* worth re-fetching — so this
  // stays retryable even though a genuinely unsupported format will exhaust
  // the retries before it fails.
  unsupportedArchive(fatal: false),
  // A format we positively recognize and do not handle (7-zip, lz4, an rpm
  // served where a tarball was promised). Unlike the case above there is
  // nothing to re-fetch: the manifest names something emb cannot unpack.
  unhandledFormat(fatal: true),
  failedOpen(fatal: false),
  invalidSha(fatal: false),
  // The bytes passed both the sha pin and the magic check; the host just has
  // no tool to test or unpack them. Re-fetching identical bytes cannot help.
  missingCmd(fatal: true);

  const _ValidationCode({required this.fatal});

  final bool fatal;
}

class _BinResult {
  _BinResult({
    required this.wasCached,
    required this.binPath,
    required this.buildDir,
  });

  final bool wasCached;
  final String binPath;

  /// The host pass's build directory. A two-pass augment needs to name it: a
  /// project that imports its generators through a generated CMake file reaches
  /// them in the build tree, not the install prefix, because that file is not
  /// installed.
  final String buildDir;
}

/// What a host pass produced: the `bin` dir to put on the cross build's PATH,
/// and the build tree, which a two-pass augment's target pass may need to name.
typedef _HostBuild = ({String binPath, String buildDir});

const Map<_ValidationCode, String> _overlayDownloadErrorMessage = {
  _ValidationCode.success: 'download successful!',
  _ValidationCode.missingFile: 'destination file missing',
  _ValidationCode.fsError: 'FileSystemException',
  _ValidationCode.corruptArchive: 'corrupt archive data',
  _ValidationCode.unsupportedArchive: 'unsupported archive format',
  _ValidationCode.unhandledFormat: 'archive format emb cannot unpack',
  _ValidationCode.failedOpen: 'failed to decompress archive',
  _ValidationCode.invalidSha: 'sha256 signature is not valid',
  _ValidationCode.missingCmd: 'required command is missing',
};

/// `tar` reads gzip/xz/bzip2/zstd itself (`-xf` sniffs the compression), so
/// every tar-based format shares one extraction argv. `%1` is the tarball,
/// `%2` the destination directory; both are substituted per element, never by
/// splitting a command string — a path containing a space would otherwise turn
/// into two arguments.
const _tarExtract = ['tar', '-xf', '%1', '-C', '%2', '--strip-components=1'];

/// Probe with the same tool that will extract: `tar -tf` reads the table of
/// contents through whatever compression `tar -xf` would sniff. Probing the
/// standalone `xz`/`zstd`/`bzip2` binaries instead would fail a host where the
/// extraction itself works — bsdtar on macOS carries all four codecs and ships
/// none of those binaries — and a probe that cannot run is fatal.
const _tarProbe = ['tar', '-tf'];

/// Formats worth naming but not handled: recognizing them turns "unsupported
/// archive format", which otherwise costs three downloads before it gives up,
/// into an immediate error that says which format arrived. Bytes are read at
/// offset 0.
const _unhandledMagics = <String, List<int>>{
  '7-zip': [0x37, 0x7a, 0xbc, 0xaf, 0x27, 0x1c],
  'lz4': [0x04, 0x22, 0x4d, 0x18],
  'lzip': [0x4c, 0x5a, 0x49, 0x50],
  'compress (.Z)': [0x1f, 0x9d],
  'rar': [0x52, 0x61, 0x72, 0x21],
  'cab': [0x4d, 0x53, 0x43, 0x46],
  'rpm': [0xed, 0xab, 0xee, 0xdb],
  'deb/ar': [0x21, 0x3c, 0x61, 0x72, 0x63, 0x68, 0x3e],
};

// Maintainable enum of supported archive formats. Each row carries its magic
// signatures and their offset, the extensions that name it, the argv that
// integrity-tests it (the tarball path is appended), and the argv that extracts
// it. Adding a format is a row here — the one piece of logic that still names a
// type is the lone-top-level-dir promotion in _fetchSource, which only zip
// needs (`unzip` has no --strip-components).
enum _ArchiveType {
  // dart format off
  gzip    ([[0x1f, 0x8b]],                          0,   _tarProbe,
                                                ['.gz', '.tgz'], _tarExtract),
  // All three local-header variants, and all four bytes of each: `PK` alone
  // also matches an uncompressed tar whose first member is named `PKGBUILD`,
  // and \x03\x04 cannot appear in a tar filename field.
  zip     ([[0x50, 0x4b, 0x03, 0x04],
            [0x50, 0x4b, 0x05, 0x06],
            [0x50, 0x4b, 0x07, 0x08]],              0,   ['unzip', '-t', '-q'],
                                                ['.zip','.jar', '.war', '.apk'],
            ['unzip', '-q', '%1', '-d', '%2']),
  xz      ([[0xfd, 0x37, 0x7a, 0x58, 0x5a, 0x00]],  0,   _tarProbe,
                                                ['.xz', '.txz'], _tarExtract),
  bzip2   ([[0x42, 0x5a, 0x68]],                    0,   _tarProbe,
                                  ['.bz2', '.tbz2', '.tbz'], _tarExtract),
  zstd    ([[0x28, 0xb5, 0x2f, 0xfd]],              0,   _tarProbe,
                                          ['.zst', '.zstd'], _tarExtract),
  // 'ustar' in ASCII bytes. Absent from the older v7/GNU layouts, which the
  // extension fallback in _validateArchive still recognizes.
  tar     ([[0x75, 0x73, 0x74, 0x61, 0x72]],        257, _tarProbe,
                                                ['.tar'], _tarExtract);
  // dart format on

  const _ArchiveType(
    this.magics,
    this.magicOffset,
    this.probeCmd,
    this.extensions,
    this.extractCmd,
  );

  /// Signatures that all identify this format; any one matching is a match.
  final List<List<int>> magics;
  final int magicOffset;
  final List<String> probeCmd;
  final List<String> extensions;
  final List<String> extractCmd;

  /// The extraction argv with `%1`/`%2` bound to [tarball] and [destDir].
  List<String> extractArgv(String tarball, String destDir) => [
    for (final a in extractCmd)
      switch (a) {
        '%1' => tarball,
        '%2' => destDir,
        _ => a,
      },
  ];

  /// Whether [magic] (the head of the file, [length] bytes of it valid) carries
  /// one of this format's signatures.
  bool matches(Uint8List magic, int length) {
    for (final sig in magics) {
      if (length < magicOffset + sig.length) continue;
      var ok = true;
      for (var i = 0; i < sig.length; i++) {
        if (magic[magicOffset + i] != sig[i]) {
          ok = false;
          break;
        }
      }
      if (ok) return true;
    }
    return false;
  }
}

/// Bytes to read from the head of a download: enough to cover the deepest
/// signature in the table (tar's `ustar` at 257). Computed once — it is a
/// property of the table, not of the file.
final _magicWindow = _ArchiveType.values
    .expand((t) => [for (final m in t.magics) t.magicOffset + m.length])
    .reduce(max);

/// A body shorter than the shortest signature in the table cannot be any
/// archive, so it is corrupt rather than unsupported.
final _magicFloor = _ArchiveType.values
    .expand((t) => [for (final m in t.magics) m.length])
    .reduce(min);

/// Ceiling on a single augment download. Source tarballs are megabytes; this is
/// only here so a hostile or misconfigured origin cannot stream until the cache
/// disk is full.
const _maxDownloadBytes = 4 * 1024 * 1024 * 1024;

/// Whether the first [length] valid bytes of [head] begin with [signature].
bool _startsWith(Uint8List head, int length, List<int> signature) {
  if (length < signature.length) return false;
  for (var i = 0; i < signature.length; i++) {
    if (head[i] != signature[i]) return false;
  }
  return true;
}

class _OverlayValidationResult {
  const _OverlayValidationResult({
    required this.code,
    this.archiveType,
    this.message,
  });

  final _ValidationCode code;
  final _ArchiveType? archiveType;

  /// Optional human-readable message printed only for fatal errors.
  final String? message;
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
       _logger = logger,
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

  /// For warnings that must outlive a spinner line (an unpinned or plain-http
  /// augment source). Null in unit tests, like [_steps].
  final Logger? _logger;

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
    final binDirs = <String>[];

    for (final lib in libs) {
      // Host tools (e.g. a code generator the cross build runs via
      // find_program) are built with the host toolchain and exposed on PATH,
      // not cross-compiled into the sysroot. They have no pkg-config presence,
      // so skip the sysroot satisfied check.
      if (lib.host) {
        final onStep = _steps?.start('augment ${lib.pkg}');
        try {
          final buildResult = await _buildHostTool(
            lib,
            overlay,
            onStep: onStep,
          );
          if (!binDirs.contains(buildResult.binPath)) {
            binDirs.add(buildResult.binPath);
          }

          if (buildResult.wasCached) {
            onStep?.complete('${lib.pkg} host cached → ${buildResult.binPath}');
          } else {
            onStep?.complete('${lib.pkg} host built → ${buildResult.binPath}');
          }
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
        if (lib.isLocal || !await _satisfied(lib)) {
          // A two-pass augment builds its generators with the host toolchain
          // first, then hands the target pass their prefix and build tree. Both
          // passes come from this one entry, so they share url, min and the
          // whole patch series — and the host pass runs inside the satisfied
          // check, because generators that exist only to build this library are
          // not worth building when the sysroot already provides it.
          String? hostBuildDir;
          if (lib.hostPass != null) {
            onStep?.update('${lib.pkg}: host pass');
            final host = await _buildHostTool(
              _hostVariant(lib),
              overlay,
              needsBuildDir: true,
              onStep: onStep,
            );
            if (!binDirs.contains(host.binPath)) binDirs.add(host.binPath);
            hostBuildDir = host.buildDir;
          }
          // What this augment can see of the ones before it — and, for a
          // two-pass augment, of its own host pass, which is why this comes
          // after it.
          final soFar = _pathsSoFar(overlay, binDirs);
          switch (lib.build) {
            case CrossGenerator.meson:
              await _buildMeson(
                lib,
                overlay,
                soFar,
                hostBuildDir: hostBuildDir,
                onStep: onStep,
              );
            case CrossGenerator.cmake:
              await _buildCMake(
                lib,
                overlay,
                soFar,
                hostBuildDir: hostBuildDir,
                onStep: onStep,
              );
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
    return _pathsSoFar(overlay, binDirs);
  }

  /// The host pass of a two-pass augment, as the single-pass `host: true`
  /// augment it is equivalent to: same source, same patch series, same subdir,
  /// built with the build machine's toolchain and installed under `host-tools`.
  ///
  /// Carries [AugmentLib.hostPassDefines] rather than `defines`, and no
  /// `hostPass` of its own — so `augmentIdentity` hashes it apart from the
  /// target pass and the two get separate host-tool stamps.
  static AugmentLib _hostVariant(AugmentLib lib) => AugmentLib(
    pkg: lib.pkg,
    minVersion: lib.minVersion,
    url: lib.url,
    path: lib.path,
    build: lib.build,
    staticLink: lib.staticLink,
    defines: lib.hostPassDefines,
    host: true,
    requiresDefine: lib.requiresDefine,
    patches: lib.patches,
    subdir: lib.subdir,
    sha256: lib.sha256,
    declaringFile: lib.declaringFile,
  );

  /// The paths an augment build can see of the augments before it: the overlay
  /// it installs into, and the host tools built so far.
  ///
  /// Augments build in manifest order, so "before" is well defined. Without
  /// this, an augment that depends on an earlier one could not find it at all —
  /// not its headers, not its `.pc` file, and not a `host: true` tool it needs
  /// to run. That is the general form of the Filament case: one tree needs a
  /// host pass whose executables the target pass then consumes.
  OverlayPaths _pathsSoFar(Directory overlay, List<String> binDirs) {
    final usr = p.join(overlay.path, 'usr');
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

  /// Build env for one augment: the profile's toolchain env, plus the overlay
  /// and host tools built before it.
  ///
  /// `PATH` is prepended with the host-tool bin dirs so a `find_program` in a
  /// later augment resolves a build-machine binary, and pkg-config is pointed
  /// at the overlay first so a later augment finds an earlier one's `.pc` file
  /// rather than only the sysroot's.
  Map<String, String> _augmentEnv(OverlayPaths paths) {
    final env = {...profile.buildEnv(), ...paths.pkgConfigEnv(profile)};
    if (paths.binDirs.isNotEmpty) {
      final inherited = Platform.environment['PATH'];
      env['PATH'] = [
        ...paths.binDirs,
        if (inherited != null && inherited.isNotEmpty) inherited,
      ].join(':');
    }
    return env;
  }

  /// `-D<key>=<value>` per define, with the augment variables expanded in the
  /// values. CMake cache entries and Meson project options are spelled the same
  /// way, and both passes go through here — a host pass inherits the entry's
  /// `defines:` (see [AugmentLib.hostPassDefines]), so a `${overlay}` written
  /// for the target pass would otherwise reach cmake verbatim.
  List<String> _defineArgs(
    AugmentLib lib,
    Directory overlay, {
    String? hostBuildDir,
  }) {
    final args = <String>[];
    for (final e in lib.defines.entries) {
      final value = _expandAugmentVars(
        e.value,
        overlay,
        lib,
        hostBuildDir: hostBuildDir,
      );
      args.add('-D${e.key}=$value');
    }
    return args;
  }

  /// Expand the placeholders an augment may use in its `defines:` values, so a
  /// build that needs to be *pointed* at an earlier augment's output can name
  /// it. Filament imports its host tools through a CMake export file rather
  /// than `find_program`, so PATH alone cannot reach it; the manifest has to
  /// name the prefix.
  ///
  /// `${overlay}` is where augments install (`<overlay>/usr`), and
  /// `${host_tools}` is the root holding one `<pkg>/usr` prefix per `host: true`
  /// augment — composable, so a manifest writes `${host_tools}/<pkg>/usr`.
  ///
  /// A two-pass augment (`host_pass:`) gets two more, both naming its own host
  /// pass so the entry need not repeat its own `pkg`: `${host_prefix}` is that
  /// install prefix, and `${host_build}` the build tree. The build tree is the
  /// one that matters for Filament — the file that imports `matc` and friends
  /// is generated there and never installed. Both are left verbatim for a
  /// single-pass augment, where they name nothing; `AugmentLib.fromMap` rejects
  /// them at load for exactly that reason, so reaching here unexpanded means
  /// the host pass ran and reported no build directory.
  String _expandAugmentVars(
    String value,
    Directory overlay,
    AugmentLib lib, {
    String? hostBuildDir,
  }) {
    final hostTools = workspace.platformDir('host-tools').path;
    var out = value
        .replaceAll(r'${overlay}', p.join(overlay.path, 'usr'))
        .replaceAll(r'${host_tools}', hostTools);
    if (lib.hostPass == null) return out;
    out = out.replaceAll(r'${host_prefix}', p.join(hostTools, lib.pkg, 'usr'));
    if (hostBuildDir != null && hostBuildDir.isNotEmpty) {
      out = out.replaceAll(r'${host_build}', hostBuildDir);
    }
    return out;
  }

  /// The directory to configure: [AugmentLib.subdir] under the unpacked tree,
  /// or its root. Patches still apply against the root (see `_fetchSource`),
  /// so a patch path stays repo-relative either way.
  ///
  /// Both passes of a two-pass augment go through here. The host pass used to
  /// configure the root unconditionally, which was wrong for any `host: true`
  /// entry carrying a `subdir:` — the key named a subtree and the build ignored
  /// it.
  static String _configureDir(AugmentLib lib, Directory src) {
    final sub = lib.subdir;
    return sub == null || sub.isEmpty ? src.path : p.join(src.path, sub);
  }

  /// A fresh build dir for [lib]'s source — wiped first so a re-run never
  /// reuses a stale (possibly mis-configured) meson/cmake cache.
  ///
  /// For a downloaded tarball that is `_build/` inside the unpacked tree, which
  /// emb owns and re-unpacks at will. A local tree belongs to the developer, so
  /// its build dir goes in the workspace instead: emb creates and deletes this
  /// directory on every run, which is not something to do inside someone's
  /// checkout.
  ///
  /// [host] gives the host pass its own directory. The two passes of one
  /// augment share an unpacked tree — it is keyed on `pkg` and `min` — so
  /// without this the target pass's wipe takes the host pass's build tree with
  /// it, and anything the target pass was told to import from it is gone.
  Directory _freshBuildDir(AugmentLib lib, Directory src, {bool host = false}) {
    final suffix = host ? '-host' : '';
    final bld = lib.isLocal
        ? Directory(
            p.join(
              workspace.ensurePlatformDir('overlay-build').path,
              '${lib.pkg}-local$suffix',
            ),
          )
        : Directory(p.join(src.path, '_build$suffix'));
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

  /// Classifies [tarball]: a [sha] match when the manifest pins one, then
  /// recognized magic bytes, then a passing integrity probe.
  /// A cached download can be truncated (an interrupted fetch, a disk-full
  /// write) or hold an HTML error page saved under a tarball name; trusting
  /// `existsSync()` alone lets those through, and the failure only surfaces
  /// later as a misleading patch error against an empty tree.
  /// A non-fatal result means the bytes are suspect, so the caller deletes and
  /// re-downloads; a fatal one ([_ValidationCode.fatal]) means the host is at
  /// fault, so the file is kept and the build stops.
  Future<_OverlayValidationResult> _validateArchive(
    File tarball,
    String? sha,
  ) async {
    // Check 0: is the file present?
    if (!tarball.existsSync()) {
      return const _OverlayValidationResult(code: _ValidationCode.missingFile);
    }

    // Check 1: is SHA256 valid?
    final expected = sha?.toLowerCase();
    if (expected != null) {
      final actual = await _sha256(tarball);
      if (actual != expected) {
        return const _OverlayValidationResult(code: _ValidationCode.invalidSha);
      }
    }

    // Check 2: are the magic bytes valid for archive type? A format may pin
    // its magic at a nonzero offset (tar's 'ustar' sits at 257), so read a
    // window wide enough to cover the deepest one and compare per-type.
    final magic = Uint8List(_magicWindow);
    // Bytes actually read: the buffer is always [_magicWindow] long and
    // zero-filled past the end of a short file, so comparing against its length
    // would let a 3-byte file "match" any signature made of leading zeros.
    var magicLength = 0;
    try {
      final raf = await tarball.open();
      try {
        // Looped: a single readInto may return short on a FUSE or
        // network-backed cache dir, which would silently skip tar's signature
        // at 257 and mis-detect the file.
        while (magicLength < _magicWindow) {
          final n = await raf.readInto(magic, magicLength, _magicWindow);
          if (n == 0) break;
          magicLength += n;
        }
        if (magicLength < _magicFloor) {
          return const _OverlayValidationResult(
            code: _ValidationCode.corruptArchive,
          );
        }
      } finally {
        await raf.close();
      }
    } on FileSystemException catch (e) {
      // Carry the OS message: "FileSystemException" on its own says nothing
      // about whether this is permissions, ENOSPC or a vanished cache dir.
      return _OverlayValidationResult(
        code: _ValidationCode.fsError,
        message: '${e.message}${e.osError == null ? '' : ' (${e.osError})'}',
      );
    }

    final lowerPath = tarball.path.toLowerCase();
    _ArchiveType? archiveType;
    _ArchiveType? namedByExtension;
    for (final type in _ArchiveType.values) {
      final matchesExtension = type.extensions.any(lowerPath.endsWith);
      if (matchesExtension) namedByExtension ??= type;
      if (!type.matches(magic, magicLength)) continue;
      // Magic AND extension match -> unambiguous.
      if (matchesExtension) {
        archiveType = type;
        break;
      }
      // Magic only: keep scanning for a type whose extension also matches, so
      // a later both-match row beats this one. Content still wins over a name
      // that matches nothing — a zip served as `.tar.gz` unpacks as a zip.
      archiveType ??= type;
    }

    // No signature matched. A format we recognize but do not handle is named
    // outright and is fatal; a name we know with bytes we don't is a bad body
    // (an HTML error page under a .tar.gz name), and so is a body that matches
    // nothing at all — both retryable, because a re-fetch can fix them.
    if (archiveType == null) {
      for (final entry in _unhandledMagics.entries) {
        if (!_startsWith(magic, magicLength, entry.value)) continue;
        return _OverlayValidationResult(
          code: _ValidationCode.unhandledFormat,
          message:
              'The download is ${entry.key}, which emb does not unpack. '
              'Point url: at a tar or zip archive instead.',
        );
      }
      // An extension we know with no signature to back it: older v7/GNU tars
      // carry no `ustar` at 257, so let the probe have the final say rather
      // than deleting a file that `tar` can read.
      if (namedByExtension != null && namedByExtension.magicOffset > 0) {
        archiveType = namedByExtension;
      } else if (namedByExtension != null) {
        return const _OverlayValidationResult(
          code: _ValidationCode.corruptArchive,
        );
      } else {
        return const _OverlayValidationResult(
          code: _ValidationCode.unsupportedArchive,
        );
      }
    }

    // Check 3: does the file open?
    // The two arms are not duplicates, and the distinction is what decides
    // whether the tarball is thrown away: a nonzero exit means the probe ran
    // and refused the bytes (retryable), while a ProcessException means it was
    // never spawned — missing, not executable, or exec-format mismatch — which
    // says nothing about the bytes and is fatal. No `which` pre-check: spawning
    // the probe answers the same question without making `which` itself a
    // dependency of every fetch.
    final cmd = archiveType.probeCmd.first;
    final args = [...archiveType.probeCmd.skip(1), tarball.path];
    try {
      final test = await _run(cmd, args);
      if (test.exitCode != 0) {
        return const _OverlayValidationResult(code: _ValidationCode.failedOpen);
      }
    } on ProcessException {
      return _OverlayValidationResult(
        code: _ValidationCode.missingCmd,
        archiveType: archiveType,
        message:
            'Could not run "$cmd" to verify ${p.basename(tarball.path)}. '
            'Install it (and check it is on PATH and executable), then build '
            'again — the download itself is fine and has been kept.',
      );
    }

    return _OverlayValidationResult(
      code: _ValidationCode.success,
      archiveType: archiveType,
    );
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
    // Serialize on the package: every name in the cache derives from `pkg` and
    // `min` alone, so two runs over one checkout — `--target A` alongside
    // `--target B`, or two CI jobs sharing a workspace — otherwise interleave
    // `.part` writes, delete each other's staging dir, and race the promotion
    // rename, which surfaces as a raw FileSystemException rather than a
    // reported build failure.
    return withFileLock(
      File(p.join(src.path, '.${lib.pkg}.lock')),
      () => _fetchRemoteSource(lib, src, onStep: onStep),
    );
  }

  /// The body of [_fetchSource] for a `url:` augment, run under the per-package
  /// cache lock.
  Future<Directory> _fetchRemoteSource(
    AugmentLib lib,
    Directory src, {
    StepHandle? onStep,
  }) async {
    // Prefix the package name so two augments whose URLs share a basename
    // (e.g. two vendors both publishing `v1.0.0.tar.gz`) can't collide on,
    // and then cross-validate, the same cached tarball.
    final tarball = File(
      p.join(src.path, '${lib.pkg}-${_urlBasename(lib.url)}'),
    );
    final dir = Directory(p.join(src.path, '${lib.pkg}-${lib.minVersion}'));
    // Belt and braces over the `pkg`/`min` charset check in AugmentLib: these
    // two paths are written to, renamed onto and deleted recursively, so a
    // future parsing change must not be able to aim them outside the cache.
    _assertInsideCache(lib, src, tarball.path);
    _assertInsideCache(lib, src, dir.path);

    if (Uri.parse(lib.url).scheme == 'http') {
      _logger?.warn(
        'augment ${lib.pkg}: url is plain http — anyone on the path chooses '
        'the source emb compiles. Prefer https.',
      );
    }
    if (lib.sha256 == null) {
      _logger?.warn(
        'augment ${lib.pkg}: no sha256 — whoever answers '
        '${Uri.parse(lib.url).host} decides what gets built. The archive '
        'checks below detect corruption, not substitution; pin the digest.',
      );
    }

    // An unpacked tree is reused as-is, which stays correct only while what
    // shaped it is unchanged: the source it came from (url + pin) and the patch
    // series on top. Leaving url/sha out of the stamp meant repointing `url:`
    // at a new tag while `min:` stayed put re-downloaded the tarball and then
    // built the *old* tree — and that a tree unpacked from a substituted
    // tarball survived adding the correct pin afterwards.
    // Patch paths are already absolute: CrossTarget.withResolvedPatches rebases
    // them against the declaring manifest at load, so the paths hashed into the
    // cache keys and the paths applied here are the same files.
    // The stamp is written even when there are no patches, so a directory only
    // survives reuse when this code created it — stale trees from older runs or
    // hand-made dirs carry no stamp, mismatch the current key, and get
    // re-unpacked; without that guard a no-patch augment could silently reuse
    // an empty foreign dir (the original bug we are fixing).
    final patches = lib.patches;
    final treeKey = contentHash([
      lib.url,
      lib.sha256 ?? '',
      if (patches.isEmpty) '' else patchSeriesDigest(patches),
    ]);
    final stamp = File(p.join(dir.path, '.emb-patch-stamp'));
    final treeIsCurrent =
        dir.existsSync() &&
        stamp.existsSync() &&
        stamp.readAsStringSync().trim() == treeKey;
    // Ask the tree before the tarball: when the tree is ours and current there
    // is nothing to fetch and nothing to check. Validating first cost a full
    // SHA-256 stream plus a probe that reads the whole archive on every build,
    // and re-downloaded the tarball outright for anyone who prunes tarballs to
    // reclaim disk while keeping the extracted trees.
    if (treeIsCurrent) {
      onStep?.update('${lib.pkg} source cached');
      return dir;
    }

    // Retry downloading: a sha-pinned source whose bytes don't match the
    // pin is deleted and re-fetched (an upstream mirror swap or a half-written
    // body recover cleanly), and the last mismatch is a real manifest/upstream
    // divergence that must fail loudly, not loop. The final "fetched" label
    // stays on this handle until the caller completes/fails it —
    // StepHandle.complete() may only be called once per spinner.
    const maxAttempts = 3;
    _OverlayValidationResult? result;

    for (var attempts = 0; ; attempts++) {
      // Check previous attempt
      if (tarball.existsSync()) {
        // If tarball is valid, skip download
        result = await _validateArchive(tarball, lib.sha256);

        if (result.code == _ValidationCode.success) {
          // A usable archive was already in the cache before we tried to fetch.
          if (attempts == 0) {
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
          // A fatal result is not about the bytes: re-fetching the same body
          // cannot help, and it is worth keeping — the user installs the
          // missing tool (or looks at what the server actually sent) and builds
          // again without paying for the download twice. So throw *before* the
          // delete below.
          if (result.code.fatal) {
            throw OverlayBuildException(
              '${lib.pkg}: cannot use this download (${lib.url})\n'
              '${_overlayDownloadErrorMessage[result.code]}'
              '${result.message == null ? '' : '\n${result.message}'}\n'
              'Kept at ${tarball.path}',
            );
          }
          _io(lib, 'discarding the bad download', tarball.deleteSync);
        }
      }

      if (attempts == maxAttempts) {
        throw OverlayBuildException(
          '${lib.pkg}: '
          '${_overlayDownloadErrorMessage[result?.code] ?? 'download failed'}'
          ' after $maxAttempts attempts (${lib.url})'
          '${result?.message == null ? '' : '\n${result!.message}'}',
        );
      }

      // Try downloading
      onStep?.update(
        'Downloading ${lib.pkg} (attempt ${attempts + 1}/$maxAttempts)',
      );
      // `_download` retries transient failures internally and raises
      // OverlayBuildException on a hard one, which build()'s handler turns into
      // a failed spinner rather than a stuck one.
      await _download(lib.url, tarball);
    }

    // Reuse is only safe when this code wrote the tree from *this* source: an
    // absent stamp or a stale key means wipe and re-unpack.
    if (dir.existsSync()) {
      _io(lib, 'clearing the stale source tree', () {
        dir.deleteSync(recursive: true);
      });
    }

    if (!dir.existsSync()) {
      onStep?.update('Extracting ${lib.pkg}…');
      // Extract into a staging dir and promote it only on success, so a
      // failing extraction (corrupt tarball, `tar` exit != 0) can never leave
      // a pre-created empty [dir] behind for the next run to reuse — that
      // hole is what turned a bad download into a misleading patch error
      // against an empty tree.
      final stage = Directory('${dir.path}.unzip');
      _io(lib, 'preparing the staging dir', () {
        if (stage.existsSync()) stage.deleteSync(recursive: true);
        stage.createSync(recursive: true);
      });
      // Use the appropriate extraction command based on the file type.
      final archiveType = result.archiveType!;
      final extract = archiveType.extractArgv(tarball.path, stage.path);
      final extracted = await _run(extract.first, extract.sublist(1));
      final detail = [
        extracted.stdout,
        extracted.stderr,
      ].map((s) => s.trim()).where((s) => s.isNotEmpty).join('\n');
      if (extracted.exitCode != 0) {
        // A non-zero exit is also how both tools refuse a hostile member name:
        // GNU tar rejects `..` outright, and unzip rewrites a traversal and
        // still exits non-zero. Wiping the stage keeps a partial unpack from
        // being reused.
        _io(lib, 'clearing the staging dir', () {
          stage.deleteSync(recursive: true);
        });
        throw OverlayBuildException(
          '${lib.pkg}: extract failed (exit ${extracted.exitCode}) '
          'from ${tarball.path}'
          '${detail.isEmpty ? '' : '\n$detail'}',
        );
      }
      if (stage.listSync(followLinks: false).isEmpty) {
        // Exit 0 on an empty archive (e.g. a stub tarball) would otherwise
        // produce an empty source tree that "builds" into nothing.
        _io(lib, 'clearing the staging dir', () {
          stage.deleteSync(recursive: true);
        });
        throw OverlayBuildException(
          '${lib.pkg}: extract produced no files from ${tarball.path}'
          '${detail.isEmpty ? '' : '\n$detail'}',
        );
      }
      // Keyed on the detected type, not the filename: a zip served as
      // `/tarball/v1.2.3`, a `.jar`, or one misnamed `.tar.gz` all extract
      // through `unzip` and so all need this promotion. Testing the name here
      // would unpack them one directory too deep and fail configure with a
      // puzzling "no meson.build".
      _io(lib, 'promoting the extracted tree', () {
        if (archiveType == _ArchiveType.zip) {
          // followLinks: false, and the type re-checked without following:
          // listSync() reports a symlink-to-directory as a Directory, so an
          // archive whose single top-level member is a symlink could otherwise
          // be promoted as-is — leaving the source dir a link to wherever the
          // archive pointed, which the stamp write, the `_build` wipe and the
          // configure step would then all follow out of the cache.
          final top = stage.listSync(followLinks: false);
          final onlyDir =
              top.length == 1 &&
              FileSystemEntity.typeSync(top.single.path, followLinks: false) ==
                  FileSystemEntityType.directory;
          if (onlyDir) {
            Directory(top.single.path).renameSync(dir.path);
            stage.deleteSync(recursive: true);
            return;
          }
        }
        stage.renameSync(dir.path);
      });

      // Patch the freshly unpacked tree, then stamp it. On failure the tree is
      // removed so the next run unpacks clean rather than reusing a partially
      // patched source -- which would still build, silently producing
      // something that does not match the manifest.
      if (patches.isNotEmpty) {
        try {
          await applyPatchSeries(
            runner: (args, {required workingDirectory}) =>
                Process.run('git', args, workingDirectory: workingDirectory),
            workDir: dir.absolute.path,
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
      _io(lib, 'stamping the source tree', () {
        stamp.writeAsStringSync(treeKey);
      });
    }
    return dir;
  }

  Future<void> _buildMeson(
    AugmentLib lib,
    Directory overlay,
    OverlayPaths soFar, {
    String? hostBuildDir,
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
        ..._defineArgs(lib, overlay, hostBuildDir: hostBuildDir),
      ],
      environment: _augmentEnv(soFar),
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
    Directory overlay,
    OverlayPaths soFar, {
    String? hostBuildDir,
    StepHandle? onStep,
  }) async {
    final src = await _fetchSource(lib, onStep: onStep);
    final srcDir = _configureDir(lib, src);
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
        ..._defineArgs(lib, overlay, hostBuildDir: hostBuildDir),
      ],
      environment: _augmentEnv(soFar),
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
  /// prepend to the cross build's PATH, plus the build directory it used.
  ///
  /// Deliberately passes no cross toolchain file and no `profile.buildEnv()` —
  /// the tool must run on the build machine, so it uses the host compiler and
  /// the inherited host environment.
  ///
  /// A stamp keyed on [augmentIdentity] plus host OS, arch, and compiler
  /// versions skips the build when the inputs haven't changed — host tools are
  /// otherwise rebuilt on every `--build` because `_freshBuildDir` wipes the
  /// cmake dir. The stamp is deleted before each build so a failed install
  /// doesn't leave a stale hit; the payload dir is also checked so a partial
  /// prune falls through to a rebuild rather than returning a bad path.
  ///
  /// [needsBuildDir] adds the build tree to what the stamp vouches for. A plain
  /// `host: true` augment is consumed through its install prefix and PATH, so
  /// the build tree may be pruned without invalidating the stamp; a two-pass
  /// augment names that tree in its target pass, so a hit that cannot produce
  /// it is useless and falls through to a rebuild.
  Future<_BinResult> _buildHostTool(
    AugmentLib lib,
    Directory overlay, {
    bool needsBuildDir = false,
    StepHandle? onStep,
  }) async {
    final hostTools = workspace.ensurePlatformDir('host-tools');
    final toolDir = Directory(p.join(hostTools.path, lib.pkg))
      ..createSync(recursive: true);
    final stampFile = File(p.join(toolDir.path, 'stamp'));
    final buildDirFile = File(p.join(toolDir.path, 'build-dir'));
    final key = await _hostToolKey(lib);
    final binDir = p.join(toolDir.path, 'usr', 'bin');
    if (stampFile.existsSync() &&
        stampFile.readAsStringSync().trim() == key &&
        Directory(binDir).existsSync()) {
      final recorded = buildDirFile.existsSync()
          ? buildDirFile.readAsStringSync().trim()
          : '';
      if (!needsBuildDir ||
          (recorded.isNotEmpty && Directory(recorded).existsSync())) {
        return _BinResult(wasCached: true, binPath: binDir, buildDir: recorded);
      }
    }
    if (stampFile.existsSync()) stampFile.deleteSync();
    final built = await switch (lib.build) {
      CrossGenerator.cmake => _buildCMakeHost(
        lib,
        overlay,
        toolDir,
        onStep: onStep,
      ),
      CrossGenerator.meson => _buildMesonHost(
        lib,
        overlay,
        toolDir,
        onStep: onStep,
      ),
    };
    Directory(built.binPath).createSync(recursive: true);
    buildDirFile.writeAsStringSync(built.buildDir);
    stampFile.writeAsStringSync(key);
    return _BinResult(
      wasCached: false,
      binPath: built.binPath,
      buildDir: built.buildDir,
    );
  }

  Future<String> _hostToolKey(AugmentLib lib) async => contentHash([
    augmentIdentity(lib),
    Platform.operatingSystem,
    Abi.current().toString(),
    await _compilerVersions(),
  ]);

  Future<_HostBuild> _buildCMakeHost(
    AugmentLib lib,
    Directory overlay,
    Directory toolDir, {
    StepHandle? onStep,
  }) async {
    final src = await _fetchSource(lib, onStep: onStep);
    final bld = _freshBuildDir(lib, src, host: true);
    _check(
      lib,
      'cmake configure (host)',
      await _run('cmake', [
        '-S',
        _configureDir(lib, src),
        '-B',
        bld.path,
        '-DCMAKE_INSTALL_PREFIX=/usr',
        '-DCMAKE_BUILD_TYPE=Release',
        ..._defineArgs(lib, overlay),
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
    return (binPath: p.join(toolDir.path, 'usr', 'bin'), buildDir: bld.path);
  }

  Future<_HostBuild> _buildMesonHost(
    AugmentLib lib,
    Directory overlay,
    Directory toolDir, {
    StepHandle? onStep,
  }) async {
    final src = await _fetchSource(lib, onStep: onStep);
    final bld = _freshBuildDir(lib, src, host: true);
    _check(
      lib,
      'meson setup (host)',
      await _run('meson', [
        'setup',
        bld.path,
        _configureDir(lib, src),
        '--prefix',
        '/usr',
        '--libdir',
        'lib',
        '--buildtype',
        'release',
        ..._defineArgs(lib, overlay),
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
    return (binPath: p.join(toolDir.path, 'usr', 'bin'), buildDir: bld.path);
  }

  /// The cache filename for [url]'s basename. A URL whose path ends in `/` (or
  /// has none) has no basename, which would otherwise name the cache entry
  /// `<pkg>-` and read as a truncation in every later error message.
  static String _urlBasename(String url) {
    final base = p.basename(Uri.parse(url).path);
    final cleaned = base.replaceAll('/', '');
    return cleaned.isEmpty ? 'source' : cleaned;
  }

  /// Refuse a cache path that escaped [cache]. `p.join` drops its base when the
  /// next part is absolute, so a `pkg:`/`min:` carrying `/` or `..` would aim
  /// the writes — and the recursive deletes — at the developer's own files.
  void _assertInsideCache(AugmentLib lib, Directory cache, String path) {
    final root = p.canonicalize(cache.path);
    final target = p.canonicalize(path);
    if (target == root || !p.isWithin(root, target)) {
      throw OverlayBuildException(
        '${lib.pkg}: refusing to use "$path" — it resolves outside the source '
        'cache ($root). Check pkg:/min: in the manifest.',
      );
    }
  }

  /// Run a filesystem mutation, reporting a failure as a build error rather
  /// than an uncaught FileSystemException. These paths are shared with the
  /// user's own housekeeping, so a vanished directory or a cross-device rename
  /// must read as a reported failure, not a stack trace.
  T _io<T>(AugmentLib lib, String what, T Function() body) {
    try {
      return body();
    } on FileSystemException catch (e) {
      throw OverlayBuildException(
        '${lib.pkg}: $what failed — ${e.message}'
        '${e.path == null ? '' : ' (${e.path})'}'
        '${e.osError == null ? '' : ': ${e.osError!.message}'}',
      );
    }
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
          // Counted rather than piped: an augment URL can answer with anything,
          // and an unbounded `pipe` lets a hostile (or misconfigured) origin
          // fill the cache disk. The cap is far above any real source tarball.
          // Note this bounds the *download*; a compression bomb still expands
          // unbounded at extraction, which neither `tar` nor `unzip` can limit.
          final sink = part.openWrite();
          var written = 0;
          try {
            await resp.forEach((chunk) {
              written += chunk.length;
              if (written > _maxDownloadBytes) {
                throw OverlayBuildException(
                  'download exceeded ${_bytes(_maxDownloadBytes)} ($url)',
                );
              }
              sink.add(chunk);
            });
          } finally {
            await sink.close();
          }
          // A chunked response cut short otherwise lands as a short file that
          // only the archive probe notices, three downloads later.
          if (resp.contentLength > 0 && written != resp.contentLength) {
            if (part.existsSync()) part.deleteSync();
            throw OverlayBuildException(
              'download truncated ($url): got $written of '
              '${resp.contentLength} bytes',
            );
          }
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
      } on OverlayBuildException {
        // Over the cap or short of the promised length: the partial body is
        // useless and must not be left where the next run could trust it.
        if (part.existsSync()) part.deleteSync();
        rethrow;
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
