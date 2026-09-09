import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:emb_cli/src/cross/cross_keys.dart';
import 'package:emb_cli/src/cross/cross_profile.dart';
import 'package:emb_cli/src/cross/cross_provider.dart';
import 'package:emb_cli/src/cross/cross_target.dart';
import 'package:emb_cli/src/cross/emb_lock.dart';
import 'package:emb_cli/src/host/host_info.dart';
import 'package:emb_cli/src/workspace/workspace.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

/// Resolves a relocatable Yocto SDK (`populate_sdk` output) into a
/// [CrossProfile].
///
/// The SDK ships a single `environment-setup-<triple>` script that, when
/// sourced, exports the compiler, both sysroots (`OECORE_NATIVE_SYSROOT` +
/// `SDKTARGETSYSROOT`), the tuning flags (`CFLAGS`/`CXXFLAGS`/`LDFLAGS`), the
/// pkg-config wiring, and a ready `OEToolchainConfig.cmake`. Rather than
/// re-deriving any of that, this provider *sources the script in a clean shell
/// and reads the environment back* — so it tracks SDK/version drift exactly
/// and never duplicates OE's `-march`/`-mbranch-protection` math by hand.
///
/// The captured env becomes the profile's [CrossProfile.extraEnv]; the build
/// stage runs configure/build under it, so `CC`/`CXX`/`CFLAGS` and
/// `CMAKE_TOOLCHAIN_FILE` flow through verbatim.
class YoctoSdkCrossProvider implements CrossProvider {
  YoctoSdkCrossProvider(
    this.target, {
    required this.workspace,
    required this.host,
    HttpClient? httpClient,
  }) : _http = httpClient ?? HttpClient();

  final CrossTarget target;
  final Workspace workspace;
  final HostInfo host;
  final HttpClient _http;

  /// Artifacts this resolve (re)materialized, recorded for `emb.lock` — the
  /// downloaded installer when sdk_url is used. A local sdk_path install
  /// fetches nothing, so this stays empty (the SDK version still pins it).
  final List<LockedArtifact> _artifacts = [];

  /// Set when a download attempt fails, so the caller can include the reason
  /// in the user-facing error rather than just "no environment-setup-* found".
  String? _failureDetail;

  @override
  String get name => 'yocto-sdk';

  @override
  String get triple => target.targetTriple ?? 'aarch64-poky-linux';

  // The SDK is relocatable. bash runs a downloaded installer when sdk_url is
  // used, and sources the environment-setup script.
  @override
  List<String> get preflightTools => const ['bash', 'sh'];

  @override
  List<({String kind, String key})> cacheSelectors() => const [];

  /// Close the underlying HTTP client.
  void close() => _http.close(force: true);

  /// OE env keys we lift into a typed [CrossProfile]. Everything captured is
  /// also kept in [CrossProfile.extraEnv]; these are the few we also surface
  /// as first-class fields.
  static const _sdkTargetSysroot = 'SDKTARGETSYSROOT';
  static const _nativeSysroot = 'OECORE_NATIVE_SYSROOT';
  static const _targetArch = 'OECORE_TARGET_ARCH';
  static const _targetOs = 'OECORE_TARGET_OS';
  static const _sdkVersion = 'OECORE_SDK_VERSION';

  @override
  Future<CrossResolveResult> resolve() async {
    _failureDetail = null;
    _artifacts.clear();
    final envSetup = await _resolveEnvSetup();
    if (envSetup == null) {
      final detail = _failureDetail != null ? ' ($_failureDetail)' : '';
      return CrossResolveResult.unavailable(
        'no environment-setup-* found$detail — set cross.sdk_path to an '
        'installed SDK, cross.sdk_url to a populate_sdk installer, or '
        'cross.sdk_env_setup directly',
      );
    }

    final env = await _sourceEnv(envSetup);
    if (env == null) {
      return const CrossResolveResult.failed(
        'failed to source the SDK environment-setup script',
      );
    }

    final targetSysroot = env[_sdkTargetSysroot];
    if (targetSysroot == null || targetSysroot.isEmpty) {
      return CrossResolveResult.failed(
        'SDK env did not export $_sdkTargetSysroot (sourced: $envSetup)',
      );
    }

    // CC/CXX in an OE env are full invocations, e.g.
    //   "aarch64-poky-linux-gcc -mcpu=... --sysroot=$SDKTARGETSYSROOT".
    // Keep the whole string in extraEnv (the build applies it verbatim); the
    // bare binary is split out only for the typed cc/cxx fields.
    final ccFull = env['CC'] ?? '';
    final cxxFull = env['CXX'] ?? '';
    final triple = target.targetTriple ?? _deriveTriple(env);

    final cmakeTc =
        env['CMAKE_TOOLCHAIN_FILE'] ??
        env['OE_CMAKE_TOOLCHAIN_FILE'] ??
        _defaultOeCmake(env[_nativeSysroot]);
    final mesonCross = _locateMesonCross(env[_nativeSysroot]);

    final profile = CrossProfile(
      providerName: name,
      targetTriple: triple,
      cc: _firstToken(ccFull),
      cxx: _firstToken(cxxFull),
      ar: env['AR'] != null ? _firstToken(env['AR']!) : '$triple-ar',
      strip: env['STRIP'] != null
          ? _firstToken(env['STRIP']!)
          : '$triple-strip',
      targetSysroot: targetSysroot,
      nativeSysroot: env[_nativeSysroot],
      cFlags: _split(env['CFLAGS']),
      cxxFlags: _split(env['CXXFLAGS']),
      ldFlags: _split(env['LDFLAGS']),
      pkgConfig: PkgConfig(
        sysrootDir: env['PKG_CONFIG_SYSROOT_DIR'] ?? targetSysroot,
        path: _split(env['PKG_CONFIG_PATH'], sep: ':'),
      ),
      cmakeToolchainFile: cmakeTc,
      mesonCrossFile: mesonCross,
      // The full sourced env IS the cross environment. PATH is prepended with
      // the native-sysroot bins by the setup script, so the build finds the
      // SDK's cmake/meson/ninja wrappers ahead of any host copies.
      extraEnv: env,
    );
    final lockEntry = LockedTarget(
      provider: name,
      triple: triple,
      // The OE SDK version — pins a local sdk_path install (no artifact to
      // sha), and catches a version change under an unchanged sdk_url too.
      toolchainVersion: env[_sdkVersion],
      sysrootKey: sysrootKey(target),
      buildKey: buildKey(target),
      artifacts: _artifacts,
    );
    return CrossResolveResult.ok(profile, lockEntry: lockEntry);
  }

  /// Resolve the `environment-setup-*` script from whichever SDK location is
  /// configured: an explicit env-setup, an installed `sdk_path`, or a
  /// downloadable `sdk_url` (materialized into a workspace prefix first).
  Future<String?> _resolveEnvSetup() async {
    // 1) Explicit env-setup wins.
    final explicit = target.sdkEnvSetup;
    if (explicit != null && File(explicit).existsSync()) return explicit;

    // 2) An already-installed SDK path.
    final localRoot = target.sdkPath;
    if (localRoot != null && Directory(localRoot).existsSync()) {
      final found = _globEnvSetup(Directory(localRoot));
      if (found != null) return found;
    }

    // 3) A downloadable installer — materialize into the workspace, then glob.
    final url = target.sdkUrl;
    if (url != null && url.isNotEmpty) {
      final root = await _materializeFromUrl(url);
      if (root != null) return _globEnvSetup(root);
    }
    return null;
  }

  /// Find the newest `environment-setup-*` directly under [root].
  String? _globEnvSetup(Directory root) {
    if (!root.existsSync()) return null;
    final matches =
        root
            .listSync(followLinks: false)
            .whereType<File>()
            .where((f) => p.basename(f.path).startsWith('environment-setup-'))
            .toList()
          ..sort((a, b) => a.path.compareTo(b.path));
    return matches.isEmpty ? null : matches.last.path;
  }

  /// Download a `populate_sdk` self-extracting installer and run it
  /// non-interactively into a workspace prefix, returning the SDK root.
  ///
  /// The installer is the standard OE `.sh`, which accepts `-y` (assume yes)
  /// and `-d <dir>` (install dir). The prefix is keyed by the installer
  /// filename so re-resolving is a no-op once installed.
  Future<Directory?> _materializeFromUrl(String url) async {
    final sdkDir = workspace.ensurePlatformDir(
      'yocto-sdk-${sysrootKey(target)}',
    );
    final urlUri = Uri.parse(url);
    final name = p.basenameWithoutExtension(urlUri.path);
    final prefix = Directory(p.join(sdkDir.path, name));
    if (_globEnvSetup(prefix) != null) return prefix; // already installed

    final installer = File(p.join(sdkDir.path, p.basename(urlUri.path)));
    if (!installer.existsSync()) {
      if (!await _download(url, installer)) return null;
    }
    // Reached only when env-setup wasn't found above (a real (re)install), so
    // this records the installer's sha exactly when it is materialized.
    _artifacts.add(
      LockedArtifact(
        kind: ArtifactKind.sdk,
        url: url,
        sha256: await _sha256OfFile(installer),
      ),
    );
    await Process.run('chmod', ['+x', installer.path]);

    // -y: non-interactive; -d: target dir. The installer relocates the SDK's
    // baked-in paths to the chosen prefix on first run.
    // Run under `bash`, not `sh`: OE SDK installers are bash scripts and fail
    // silently under dash. Naming the interpreter rather than exec'ing the
    // script also means the install does not depend on the chmod above having
    // taken, nor on the workspace being on a filesystem mounted exec.
    final ProcessResult run;
    try {
      run = await Process.run('bash', [
        installer.path,
        '-y',
        '-d',
        prefix.path,
      ]);
    } on ProcessException catch (e) {
      _failureDetail = 'cannot run bash ${installer.path}: ${e.message}';
      return null;
    }
    if (run.exitCode != 0) {
      _failureDetail = _failMsg('SDK installer failed', run);
      return null;
    }
    return prefix;
  }

  /// Streaming sha256 of [f] — chunked so a large installer is never held in
  /// memory. Used to pin the fetched SDK installer in `emb.lock`.
  Future<String> _sha256OfFile(File f) async {
    late Digest digest;
    final input = sha256.startChunkedConversion(
      ChunkedConversionSink<Digest>.withCallback((ds) => digest = ds.single),
    );
    await for (final chunk in f.openRead()) {
      input.add(chunk);
    }
    input.close();
    return digest.toString();
  }

  Future<bool> _download(String url, File dest) async {
    final artPath = parseArtifactoryPath(url);
    var jfHint = '';
    if (artPath != null) {
      final jfResult = await _downloadViaJFrog(artPath.$1, artPath.$2, dest);
      if (jfResult != null) return jfResult;
      // jf is unusable (absent, no config, or no server for this host), so fall
      // back to plain, unauthenticated HTTP — which a private Artifactory will
      // reject. Carry the reason into whatever error the fallback produces, or
      // the user only sees a bare 401 with no hint that jf is the way in.
      jfHint =
          ' (Artifactory URL, but the jf CLI is unavailable or has no server '
          'configured for ${artPath.$1} — run `jf config add`)';
    }
    final part = File('${dest.path}.part');
    try {
      final req = await _http.getUrl(Uri.parse(url));
      req.followRedirects = true;
      final resp = await req.close();
      if (resp.statusCode != 200) {
        await resp.drain<void>();
        _failureDetail = 'HTTP ${resp.statusCode} downloading $url$jfHint';
        return false;
      }
      await resp.pipe(part.openWrite());
      part.renameSync(dest.path);
      return true;
    } on Object catch (e) {
      if (part.existsSync()) part.deleteSync();
      _failureDetail = 'connection error downloading $url: $e$jfHint';
      return false;
    }
  }

  /// Download an Artifactory file using the JFrog CLI (`jf rt dl`).
  ///
  /// Resolves the correct `--server-id` by matching [baseAuthority] against
  /// configured servers from `jf config show`, so the right credentials are
  /// used even when multiple servers are configured.
  ///
  /// Returns `true`/`false` on success/failure, or `null` when jf cannot be
  /// used (not installed, config unavailable, or no server matches
  /// [baseAuthority]); in the null case [_failureDetail] is left unchanged so
  /// the HTTP fallback owns the error message.
  Future<bool?> _downloadViaJFrog(
    String baseAuthority,
    String repoPath,
    File dest,
  ) async {
    final ProcessResult configResult;
    try {
      configResult = await Process.run('jf', ['config', 'show']);
      if (configResult.exitCode != 0) return null;
    } on ProcessException {
      return null;
    }
    final servers = parseJFrogServers(configResult.stdout as String);
    final server = servers.firstWhere(
      (s) =>
          Uri.tryParse(s['Artifactory URL'] ?? '')?.authority == baseAuthority,
      orElse: () => {},
    );
    final serverId = server['Server ID'];
    if (serverId == null) return null; // no server for this host → use HTTP

    // Download to a temp dir first, then rename atomically, so an interrupted
    // download never leaves a partial file that looks like a valid cache hit.
    // createTemp guarantees a unique name, so a leftover dir from a prior crash
    // never causes a FileSystemException here.
    final tempDir = await dest.parent.createTemp('.jf-tmp-');
    try {
      final ProcessResult result;
      try {
        result = await Process.run('jf', [
          'rt',
          'dl',
          '--flat',
          '--fail-no-op',
          '--server-id',
          serverId,
          repoPath,
          '${tempDir.path}${p.separator}',
        ]);
      } on ProcessException catch (e) {
        _failureDetail = 'jf rt dl failed: ${e.message}';
        return false;
      }
      if (result.exitCode != 0) {
        _failureDetail = _failMsg('jf rt dl failed', result);
        return false;
      }
      // Take whatever landed rather than deriving the name from the URL:
      // repoPath comes from Uri.pathSegments (decoded) while dest is named
      // from Uri.path (encoded), so a percent-encoded basename would never
      // match what jf wrote. --flat + a single-file repoPath means exactly one
      // entry is expected.
      final got = tempDir.listSync().whereType<File>().toList();
      if (got.length != 1) {
        _failureDetail = got.isEmpty
            ? 'jf rt dl reported success but downloaded nothing for $repoPath'
            : 'jf rt dl matched ${got.length} files for $repoPath; '
                  'expected exactly one';
        return false;
      }
      got.single.renameSync(dest.path);
      return true;
    } finally {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    }
  }

  static String _failMsg(String label, ProcessResult r) {
    var s = (r.stderr as String).trim();
    // Cap to avoid leaking access tokens or large outputs into error messages.
    if (s.length > 200) s = '${s.substring(0, 200)}…';
    return '$label (exit ${r.exitCode})${s.isNotEmpty ? ": $s" : ""}';
  }

  /// Parse `jf config show` stdout into server records keyed by field name.
  ///
  /// Each record contains fields like `Server ID`, `Artifactory URL`,
  /// `Default`, etc.
  @visibleForTesting
  static List<Map<String, String>> parseJFrogServers(String output) {
    final servers = <Map<String, String>>[];
    Map<String, String>? current;
    final lineRe = RegExp(r'^([^:]+):\s+(.+)$');
    for (final line in output.split('\n')) {
      final m = lineRe.firstMatch(line.trim());
      if (m == null) continue;
      final key = m.group(1)!.trim();
      final value = m.group(2)!;
      if (key == 'Server ID') {
        current = {};
        servers.add(current);
      }
      current?[key] = value;
    }
    return servers;
  }

  /// Parse an Artifactory URL into `(authority, repoPath)`.
  ///
  /// `https://host/artifactory/repo/a/b/file.sh`
  /// → `('host', 'repo/a/b/file.sh')`
  ///
  /// `https://host/artifactory/api/download/repo/a/b/file.sh`
  /// → `('host', 'repo/a/b/file.sh')`  (api/download prefix stripped)
  ///
  /// Returns null when the URL has no `/artifactory/` segment.
  @visibleForTesting
  static (String, String)? parseArtifactoryPath(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return null;
    final segments = uri.pathSegments;
    final artIdx = segments.indexOf('artifactory');
    if (artIdx < 0 || artIdx >= segments.length - 1) return null;
    var rest = segments.sublist(artIdx + 1).where((s) => s.isNotEmpty).toList();
    if (rest.length > 2 && rest[0] == 'api' && rest[1] == 'download') {
      rest = rest.sublist(2);
    }
    if (rest.isEmpty || uri.authority.isEmpty) return null;
    return (uri.authority, rest.join('/'));
  }

  /// Source [envSetup] in a clean shell and capture the resulting environment.
  ///
  /// `includeParentEnvironment: false` plus a minimal seed (only PATH, so the
  /// setup script's own tooling resolves) means the captured env is the SDK's
  /// contribution rather than a noisy diff against the caller's shell.
  Future<Map<String, String>?> _sourceEnv(String envSetup) async {
    final seedPath = Platform.environment['PATH'] ?? '/usr/bin:/bin';
    try {
      final result = await Process.run(
        'bash',
        ['-c', r'set -a; . "$EMB_ENV_SETUP" >/dev/null 2>&1; printenv'],
        environment: {'EMB_ENV_SETUP': envSetup, 'PATH': seedPath},
        includeParentEnvironment: false,
      );
      if (result.exitCode != 0) return null;
      return _parsePrintenv(result.stdout.toString());
    } on ProcessException {
      return null;
    }
  }

  /// Parse `printenv` output into a map. Splits each line on the first `=`;
  /// drops the transient seed key so it never leaks into the profile.
  Map<String, String> _parsePrintenv(String out) {
    final env = <String, String>{};
    for (final line in out.split('\n')) {
      if (line.isEmpty) continue;
      final eq = line.indexOf('=');
      if (eq <= 0) continue;
      final key = line.substring(0, eq);
      if (key == 'EMB_ENV_SETUP') continue;
      env[key] = line.substring(eq + 1);
    }
    return env;
  }

  String _defaultOeCmake(String? nativeSysroot) {
    if (nativeSysroot == null) return '';
    final candidate = p.join(
      nativeSysroot,
      'usr',
      'share',
      'cmake',
      'OEToolchainConfig.cmake',
    );
    return File(candidate).existsSync() ? candidate : '';
  }

  String? _locateMesonCross(String? nativeSysroot) {
    if (nativeSysroot == null) return null;
    final mesonDir = Directory(p.join(nativeSysroot, 'usr', 'share', 'meson'));
    if (!mesonDir.existsSync()) return null;
    final cross = mesonDir
        .listSync(followLinks: false)
        .whereType<File>()
        .where((f) => f.path.endsWith('meson.cross'))
        .toList();
    return cross.isEmpty ? null : cross.first.path;
  }

  String _deriveTriple(Map<String, String> env) {
    final arch = env[_targetArch];
    final os = env[_targetOs];
    if (arch != null && os != null) return '$arch-$os';
    return 'aarch64-poky-linux';
  }

  String _firstToken(String cmd) => cmd.trim().split(RegExp(r'\s+')).first;

  List<String> _split(String? v, {String sep = ' '}) {
    if (v == null || v.trim().isEmpty) return const [];
    return v
        .trim()
        .split(sep == ' ' ? RegExp(r'\s+') : sep)
        .where((s) => s.isNotEmpty)
        .toList();
  }
}
