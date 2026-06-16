import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:emb_cli/src/cross/cross_profile.dart';
import 'package:emb_cli/src/cross/cross_provider.dart';
import 'package:emb_cli/src/cross/cross_target.dart';
import 'package:emb_cli/src/cross/toolchain_emitter.dart';
import 'package:emb_cli/src/host/host_info.dart';
import 'package:emb_cli/src/workspace/workspace.dart';
import 'package:path/path.dart' as p;

/// Resolves a downloaded ARM GNU toolchain + an image-derived Debian sysroot
/// (the pi / radxa / beagleplay pattern).
///
/// The toolchain and sysroot are sourced independently: the toolchain is a
/// fetched-and-extracted tarball; the sysroot is unpacked from a distro image
/// and (optionally) populated with `-dev` packages via a `qemu-aarch64-static`
/// apt chroot. Because the chroot needs binfmt + root, [resolve] is Linux-host
/// only and returns [CrossResolveStatus.unavailable] elsewhere.
///
/// This is also the only provider with a probe→pick ordering edge: under
/// [ToolchainVersionPolicy.deriveFromSysroot] (unoq), the sysroot is prepared
/// first and its Debian codename selects the toolchain version, so that
/// libstdc++'s gthr/glibc assumptions match the target.
class ArmGnuCrossProvider implements CrossProvider {
  ArmGnuCrossProvider(
    this.target, {
    required this.workspace,
    required this.host,
    ToolchainEmitter emitter = const ToolchainEmitter(),
    HttpClient? httpClient,
  }) : _emitter = emitter,
       _http = httpClient ?? HttpClient();

  final CrossTarget target;
  final Workspace workspace;
  final HostInfo host;
  final ToolchainEmitter _emitter;
  final HttpClient _http;

  @override
  String get name => 'arm-gnu';

  @override
  List<String> get preflightTools => const [
    'qemu-aarch64-static',
    'tar',
    'xz',
    'rsync',
  ];

  /// Codename → ARM GNU toolchain version. The pin tracks the target's glibc:
  /// the bundled glibc must be ≤ the target's, and libstdc++'s gthr header
  /// must match the target's `pthread_cond_t` layout (reshuffled in glibc
  /// 2.41), so the toolchain can't lead the sysroot's release.
  static const _versionForCodename = {
    'bookworm': '12.3.rel1', // gcc 12, glibc 2.36
    'trixie': '15.2.rel1', // gcc 15, glibc >= 2.41
  };

  static const _defaultTriple = 'aarch64-none-linux-gnu';

  @override
  Future<CrossResolveResult> resolve() async {
    if (host.os != HostOs.linux) {
      return CrossResolveResult.unavailable(
        'arm-gnu sysroot prep needs a Linux host + root (qemu binfmt apt '
        'chroot); current host is ${host.os.name}',
      );
    }

    final triple = target.targetTriple ?? _defaultTriple;
    final platformDir = workspace.ensurePlatformDir('cross-$triple');

    // Ordering edge: derive-from-sysroot prepares the sysroot first so its
    // codename can pick the toolchain version; otherwise the version is pinned
    // and the two phases are independent.
    final sysrootDir = Directory(p.join(platformDir.path, 'sysroot'));
    String? codename;
    if (target.versionPolicy == ToolchainVersionPolicy.deriveFromSysroot) {
      final err = await _prepareSysroot(sysrootDir);
      if (err != null) return err;
      codename = _detectCodename(sysrootDir);
    }

    final version = _resolveToolchainVersion(codename);
    if (version == null) {
      return CrossResolveResult.unavailable(
        'no toolchain version: set cross.toolchain_version, or use a sysroot '
        'whose codename is one of ${_versionForCodename.keys.join(", ")}',
      );
    }

    final crossBin = await _prepareToolchain(
      version: version,
      triple: triple,
      platformDir: platformDir,
    );
    if (crossBin == null) {
      return CrossResolveResult.failed(
        'toolchain $version ($triple) fetch/extract failed',
      );
    }

    if (target.versionPolicy == ToolchainVersionPolicy.pinned) {
      final err = await _prepareSysroot(sysrootDir);
      if (err != null) return err;
    }

    final cpuFlags = target.cpuFlags;
    final cmakeTc = _emitter.emitCMake(
      outDir: platformDir,
      triple: triple,
      crossBin: crossBin,
      sysroot: sysrootDir.path,
      cpuFlags: cpuFlags,
    );

    final profile = CrossProfile(
      providerName: name,
      targetTriple: triple,
      cc: p.join(crossBin, '$triple-gcc'),
      cxx: p.join(crossBin, '$triple-g++'),
      ar: p.join(crossBin, '$triple-ar'),
      strip: p.join(crossBin, '$triple-strip'),
      targetSysroot: sysrootDir.path,
      cFlags: cpuFlags,
      cxxFlags: cpuFlags,
      pkgConfig: PkgConfig(
        sysrootDir: sysrootDir.path,
        libdir: [
          p.join(
            sysrootDir.path,
            'usr',
            'lib',
            'aarch64-linux-gnu',
            'pkgconfig',
          ),
          p.join(sysrootDir.path, 'usr', 'lib', 'pkgconfig'),
          p.join(sysrootDir.path, 'usr', 'share', 'pkgconfig'),
        ],
      ),
      cmakeToolchainFile: cmakeTc,
    );
    return CrossResolveResult.ok(profile);
  }

  /// Close the HTTP client.
  void close() => _http.close(force: true);

  String? _resolveToolchainVersion(String? codename) {
    if (target.toolchainVersion != null) return target.toolchainVersion;
    if (codename != null) return _versionForCodename[codename];
    return null;
  }

  /// Fetch + extract the ARM GNU toolchain, returning its `bin/` dir.
  Future<String?> _prepareToolchain({
    required String version,
    required String triple,
    required Directory platformDir,
  }) async {
    final tcHost = host.machineArch == 'aarch64' ? 'aarch64' : 'x86_64';
    final dirName = 'arm-gnu-toolchain-$version-$tcHost-$triple';
    final extracted = Directory(p.join(platformDir.path, 'toolchain', dirName));
    final binDir = p.join(extracted.path, 'bin');
    if (File(p.join(binDir, '$triple-gcc')).existsSync()) return binDir;

    final url =
        target.toolchainUrl ?? _defaultToolchainUrl(version, tcHost, triple);
    final downloads = Directory(p.join(platformDir.path, 'downloads'))
      ..createSync(recursive: true);
    final tarball = File(p.join(downloads.path, '$dirName.tar.xz'));
    if (!tarball.existsSync()) {
      if (!await _download(url, tarball)) return null;
    }

    extracted.parent.createSync(recursive: true);
    // --strip-components=1: the tarball nests everything under <dirName>/.
    final tar = await Process.run('tar', [
      '-xf',
      tarball.path,
      '-C',
      extracted.path.replaceFirst(RegExp(r'/[^/]+$'), ''),
    ]);
    if (tar.exitCode != 0) return null;
    return File(p.join(binDir, '$triple-gcc')).existsSync() ? binDir : null;
  }

  // ARM developer download layout. Override via cross.toolchain_url for
  // air-gapped mirrors.
  String _defaultToolchainUrl(String version, String tcHost, String triple) =>
      'https://developer.arm.com/-/media/Files/downloads/gnu/'
      '$version/binrel/arm-gnu-toolchain-$version-$tcHost-$triple.tar.xz';

  /// Acquire the sysroot into [sysrootDir]. Dispatches on the configured
  /// provenance: unpack a distro image, or rsync from a live device (unoq).
  /// Returns `null` on success, or a non-null [CrossResolveResult] to return
  /// early. Linux + (for image) root.
  ///
  /// The `-dev` package population (qemu apt chroot) is driven by the sysroot
  /// manifest layer, not the CrossTarget, so it is intentionally out of scope:
  /// this yields a base sysroot; dev-package staging is layered on before
  /// configure.
  Future<CrossResolveResult?> _prepareSysroot(Directory sysrootDir) async {
    if (File(p.join(sysrootDir.path, 'etc', 'os-release')).existsSync()) {
      return null; // already populated
    }
    final spec = target.sysroot;
    if (spec == null) {
      return const CrossResolveResult.unavailable(
        'arm-gnu needs a cross.sysroot block (image_url, or source: device)',
      );
    }
    return switch (spec.source) {
      SysrootProvenance.image => _prepareSysrootFromImage(sysrootDir, spec),
      SysrootProvenance.device => _prepareSysrootFromDevice(sysrootDir, spec),
    };
  }

  /// Unpack a distro image: download/decompress, loop-mount the rootfs
  /// partition (p2), rsync it out, relativize multiarch symlinks. Root.
  Future<CrossResolveResult?> _prepareSysrootFromImage(
    Directory sysrootDir,
    SysrootSpec spec,
  ) async {
    final imageUrl = spec.imageUrl;
    if (imageUrl == null) {
      return const CrossResolveResult.unavailable(
        'image sysroot needs cross.sysroot.image_url (or top-level image_url)',
      );
    }

    final downloads = Directory(p.join(sysrootDir.parent.path, 'downloads'))
      ..createSync(recursive: true);
    final imgXz = File(
      p.join(downloads.path, p.basename(Uri.parse(imageUrl).path)),
    );
    if (!imgXz.existsSync()) {
      if (!await _download(imageUrl, imgXz)) {
        return CrossResolveResult.failed('image download failed: $imageUrl');
      }
    }
    final img = File(imgXz.path.replaceFirst(RegExp(r'\.xz$'), ''));
    if (!img.existsSync()) {
      final un = await Process.run('xz', ['-dk', imgXz.path]);
      if (un.exitCode != 0) {
        return CrossResolveResult.failed('xz decompress failed: ${un.stderr}');
      }
    }

    sysrootDir.createSync(recursive: true);
    final mnt = await Directory.systemTemp.createTemp('emb-rootfs.');
    final loop = await Process.run('sudo', [
      'losetup',
      '--show',
      '-fP',
      img.path,
    ]);
    if (loop.exitCode != 0) {
      return CrossResolveResult.failed('losetup failed: ${loop.stderr}');
    }
    final loopDev = loop.stdout.toString().trim();
    try {
      final mount = await Process.run('sudo', [
        'mount',
        '${loopDev}p2',
        mnt.path,
      ]);
      if (mount.exitCode != 0) {
        return CrossResolveResult.failed('mount failed: ${mount.stderr}');
      }
      final rsync = await Process.run('sudo', [
        'rsync',
        '-aHAX',
        '${mnt.path}/',
        '${sysrootDir.path}/',
      ]);
      await Process.run('sudo', ['umount', mnt.path]);
      if (rsync.exitCode != 0) {
        return CrossResolveResult.failed('rsync failed: ${rsync.stderr}');
      }
    } finally {
      await Process.run('sudo', ['losetup', '-d', loopDev]);
      mnt.deleteSync(recursive: true);
    }

    _relativizeSymlinks(
      Directory(p.join(sysrootDir.path, 'usr', 'lib', 'aarch64-linux-gnu')),
    );
    return null;
  }

  /// rsync a live device's rootfs into [sysrootDir] (the unoq pattern).
  ///
  /// One SSH round-trip probes the board for rsync + PASSWORDLESS sudo: the
  /// transfer channel is non-interactive, so a sudo password prompt has no TTY
  /// and would die. With passwordless sudo we read the whole rootfs faithfully
  /// (via `rsync --rsync-path='sudo rsync'`); without it we still get every
  /// world-readable header/lib/dpkg-metadata file the cross sysroot needs, and
  /// only root-only files (shadow, private keys) are skipped — which don't
  /// matter for cross-compiling.
  Future<CrossResolveResult?> _prepareSysrootFromDevice(
    Directory sysrootDir,
    SysrootSpec spec,
  ) async {
    final host = spec.deviceHost;
    if (host == null) {
      return const CrossResolveResult.unavailable(
        'device sysroot needs cross.sysroot.host (user@host)',
      );
    }
    sysrootDir.createSync(recursive: true);

    final sshBase = [
      '-p',
      '${spec.sshPort}',
      if (spec.sshOpts != null) ...spec.sshOpts!.split(RegExp(r'\s+')),
    ];

    final probe = await Process.run('ssh', [
      ...sshBase,
      host,
      'command -v rsync >/dev/null 2>&1 && echo R; sudo -n true 2>/dev/null && echo S',
    ]);
    if (probe.exitCode != 0) {
      return CrossResolveResult.failed(
        'cannot reach $host over ssh: ${probe.stderr}',
      );
    }
    final caps = probe.stdout.toString();
    if (!caps.contains('R')) {
      return CrossResolveResult.failed('rsync not found on $host');
    }
    final passwordlessSudo = caps.contains('S');

    // rsync transport: -e 'ssh -p <port> <opts>'. With passwordless sudo, read
    // root-owned files via --rsync-path='sudo rsync'. Exclude virtual + huge
    // runtime trees that a cross sysroot never needs.
    final rshOpts = ['ssh', ...sshBase].join(' ');
    final rsyncArgs = <String>[
      '-aHAX',
      '--delete',
      '-e',
      rshOpts,
      if (passwordlessSudo) '--rsync-path=sudo rsync',
      '--exclude=/proc/*',
      '--exclude=/sys/*',
      '--exclude=/dev/*',
      '--exclude=/run/*',
      '--exclude=/tmp/*',
      '--exclude=/var/cache/*',
      '--exclude=/var/log/*',
      '--exclude=/home/*',
      '$host:/',
      '${sysrootDir.path}/',
    ];
    final rsync = await Process.run('rsync', rsyncArgs);
    if (rsync.exitCode != 0) {
      // 23/24 = partial transfer (skipped root-only files without sudo) — fine.
      if (rsync.exitCode != 23 && rsync.exitCode != 24) {
        return CrossResolveResult.failed(
          'device rsync failed: ${rsync.stderr}',
        );
      }
    }

    _relativizeSymlinks(
      Directory(p.join(sysrootDir.path, 'usr', 'lib', 'aarch64-linux-gnu')),
    );
    return null;
  }

  /// Rewrite absolute multiarch symlinks (`/usr/lib/...`) to relative targets
  /// so the linker resolves them against the sysroot rather than the host.
  void _relativizeSymlinks(Directory dir) {
    if (!dir.existsSync()) return;
    for (final e in dir.listSync(followLinks: false)) {
      if (e is Link) {
        final tgt = e.targetSync();
        if (tgt.startsWith('/')) {
          final rel = p.relative(tgt, from: '/');
          final up =
              '../' * p.split(p.relative(e.parent.path, from: '/')).length;
          e
            ..deleteSync()
            ..createSync('$up$rel');
        }
      }
    }
  }

  String? _detectCodename(Directory sysrootDir) {
    final osRel = File(p.join(sysrootDir.path, 'etc', 'os-release'));
    if (osRel.existsSync()) {
      for (final line in osRel.readAsLinesSync()) {
        if (line.startsWith('VERSION_CODENAME=')) {
          return line.split('=')[1].replaceAll('"', '').trim();
        }
      }
    }
    return null;
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

  // Retained for the sha-pinned download path (parity with EngineArtifacts).
  // ignore: unused_element
  String _sha256OfFile(File f) =>
      sha256.convert(f.readAsBytesSync()).toString();
}
