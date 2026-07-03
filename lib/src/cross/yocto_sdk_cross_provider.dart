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

  @override
  String get name => 'yocto-sdk';

  @override
  String get triple => target.targetTriple ?? 'aarch64-poky-linux';

  // The SDK is relocatable. `sh` runs a downloaded installer when sdk_url is
  // used; bash sources the environment-setup script.
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
    final envSetup = await _resolveEnvSetup();
    if (envSetup == null) {
      return const CrossResolveResult.unavailable(
        'no environment-setup-* found — set cross.sdk_path to an installed '
        'SDK, cross.sdk_url to a populate_sdk installer, or '
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
    final name = p.basenameWithoutExtension(Uri.parse(url).path);
    final prefix = Directory(p.join(sdkDir.path, name));
    if (_globEnvSetup(prefix) != null) return prefix; // already installed

    final installer = File(
      p.join(sdkDir.path, p.basename(Uri.parse(url).path)),
    );
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
    final run = await Process.run('sh', [
      installer.path,
      '-y',
      '-d',
      prefix.path,
    ]);
    if (run.exitCode != 0) return null;
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
    try {
      final req = await _http.getUrl(Uri.parse(url));
      req.followRedirects = true;
      final resp = await req.close();
      if (resp.statusCode != 200) {
        await resp.drain<void>();
        return false;
      }
      await resp.pipe(dest.openWrite());
      return true;
    } on Object {
      return false;
    }
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
