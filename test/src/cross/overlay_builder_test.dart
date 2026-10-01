import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:emb_cli/src/cross/cross_keys.dart' show contentHash;
import 'package:emb_cli/src/cross/cross_profile.dart';
import 'package:emb_cli/src/cross/cross_target.dart';
import 'package:emb_cli/src/cross/overlay_builder.dart';
import 'package:emb_cli/src/cross/process_runner.dart';
import 'package:emb_cli/src/workspace/workspace.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

const _profile = CrossProfile(
  providerName: 'arm-gnu',
  targetTriple: 'aarch64-none-linux-gnu',
  cc: '/tc/bin/aarch64-none-linux-gnu-gcc',
  cxx: '/tc/bin/aarch64-none-linux-gnu-g++',
  ar: 'ar',
  strip: 'strip',
  targetSysroot: '/sr',
  pkgConfig: PkgConfig(sysrootDir: '/sr', libdir: ['/sr/usr/lib/pkgconfig']),
  cmakeToolchainFile: '/tc.cmake',
  mesonCrossFile: '/c.cross',
);

AugmentLib _lib({String build = 'meson', bool static = true}) =>
    AugmentLib.fromMap({
      'pkg': build == 'cmake' ? 'vulkan-headers' : 'libdisplay-info',
      'min': build == 'cmake' ? '1.4.309' : '0.2.0',
      'url': build == 'cmake'
          ? 'https://x/vulkan-headers-1.4.309.tar.gz'
          : 'https://x/libdisplay-info-0.2.0.tar.gz',
      'build': build,
      'static': static,
    });

AugmentLib _hostLib({String build = 'cmake'}) {
  final pkg = build == 'meson' ? 'wayland' : 'wayland-cxx-scanner';
  return AugmentLib.fromMap({
    'pkg': pkg,
    'min': '1.0.0',
    'url': 'https://x/$pkg-1.0.0.tar.gz',
    'build': build,
    'host': true,
  });
}

/// A stand-in for an augment source origin: serves one byte body at any path,
/// so `_download` (a real `dart:io` client) fetches for real.
class _FakeOrigin {
  _FakeOrigin(this._server, this.body) {
    _server.listen((req) async {
      requests++;
      req.response.add(body);
      await req.response.close();
    });
  }

  static Future<_FakeOrigin> start(List<int> body) async =>
      _FakeOrigin(await HttpServer.bind(InternetAddress.loopbackIPv4, 0), body);

  final HttpServer _server;
  final List<int> body;
  int requests = 0;

  String get origin => 'http://127.0.0.1:${_server.port}';
  Future<void> close() => _server.close(force: true);
}

/// A runner that records invocations, reports the sysroot unsatisfied, and
/// fails the meson setup so OverlayBuilder.build stops right after _fetchSource
/// did its work.
class _StopAfterFetch {
  _StopAfterFetch({this.extractExit = 0});

  /// Exit code a real `tar` extraction returns (and this stub reports).
  final int extractExit;
  List<List<String>> calls = [];

  Future<RunResult> call(
    String exe,
    List<String> args, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool includeParentEnvironment = true,
    bool runInShell = false,
    ProcessOutputMode output = ProcessOutputMode.capture,
    String? label,
  }) async {
    calls.add([exe, ...args]);
    if (exe == 'pkg-config') return const RunResult(1, '', '');
    // `tar -tf` is the archive probe, not the extraction: it lists the members
    // and writes nothing. Only `-xf` below stands in for unpacking.
    if (exe == 'tar' && args.contains('-tf')) return const RunResult(0, '', '');
    if (exe == 'tar') {
      // Honor the stubbed extraction outcome: when [extractExit] is set to a
      // non-zero code we behave like `tar` failing mid-stream — no files are
      // written into `-C stage.path`, and the caller sees that exit code. With
      // extractExit == 0 (the default) we synthesize a successful extraction by
      // dropping a file so the empty-tree guard passes and stamping can happen.
      final dest = args[args.indexOf('-C') + 1];
      if (extractExit != 0) {
        return RunResult(extractExit, '', 'tar: stubbed failure');
      }
      File(p.join(dest, 'present.txt')).writeAsStringSync('before\n');
      return const RunResult(0, '', '');
    }
    if (exe == 'meson') return const RunResult(9, '', 'stop here');
    return const RunResult(0, '', '');
  }
}

/// Build a real `.tar.gz` at [outPath] whose entries all live under one
/// top-level directory (so the builder's `--strip-components=1` produces files
/// at the tree root). Uses the system tools because dart:io has no built-in tar
/// writer and `gzip.encode('text')` yields a gzip that extracts to nothing.
Future<void> _makeTarGz(
  String outPath, {
  required Map<String, String> entries,
}) async {
  final staging = Directory.systemTemp.createTempSync('emb_overlay_tar_');
  final top = p.join(staging.path, 'src');
  Directory(top).createSync();
  for (final e in entries.entries) {
    File(p.join(top, e.key)).writeAsStringSync(e.value);
  }
  final r = await Process.run('tar', [
    '-czf',
    outPath,
    '-C',
    staging.path,
    p.basename(top),
  ]);
  if (r.exitCode != 0) {
    throw StateError('tar failed: ${r.stderr}');
  }
  staging.deleteSync(recursive: true);
}

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('emb_overlay_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  /// Pre-stage the fetched tarball + unpacked dir so the builder never
  /// downloads or untars (isolating the build path).
  ///
  /// [name] is the unpacked directory name, `<pkg>-<min>`; the tarball name
  /// mirrors the builder's collision-proof scheme, `<pkg>-<url basename>`.
  /// The tree carries a matching patch stamp and real extracted content so it
  /// looks like this code already produced it.
  void prestage(String name) {
    final src = Directory(
      p.join(tmp.path, '.config', 'flutter_workspace', 'overlay-src'),
    )..createSync(recursive: true);
    final pkg = name.substring(0, name.lastIndexOf('-'));

    // A real tarball with entries under a single top-level dir
    // (so the builder's `--strip-components=1` produces files
    // at the tree root). This is what `_makeTarGz` builds;
    // we also unpack it straight into the staged tree so
    // pre-stage and extraction agree.
    final tarballName = '$pkg-$name.tar.gz';
    File(
      p.join(src.path, tarballName),
    ).writeAsBytesSync(gzip.encode(utf8.encode('stub\n')));

    final dir = Directory(p.join(src.path, name))..createSync(recursive: true);
    // The stamp binds the tree to the source it came from, so it has to carry
    // the same key the builder computes: url, sha pin (none here) and patch
    // series (empty here).
    File(
      p.join(dir.path, '.emb-patch-stamp'),
    ).writeAsStringSync(contentHash(['https://x/$name.tar.gz', '', '']));
  }

  test('skips a lib the sysroot already satisfies (G-04)', () async {
    final calls = <List<String>>[];
    Future<RunResult> run(
      String exe,
      List<String> args, {
      String? workingDirectory,
      Map<String, String>? environment,
      bool includeParentEnvironment = true,
      bool runInShell = false,
      ProcessOutputMode output = ProcessOutputMode.capture,
      String? label,
    }) async {
      calls.add([exe, ...args]);
      return const RunResult(0, '', ''); // pkg-config: satisfied
    }

    final ob = OverlayBuilder(Workspace(tmp), _profile, runProcess: run);
    final paths = await ob.build([_lib()]);
    ob.close();

    expect(paths.prefix, contains('overlay-'));
    expect(calls, hasLength(1)); // only the pkg-config probe
    expect(calls.single.first, 'pkg-config');
  });

  test('builds a meson lib with --cross-file + DESTDIR (G-05)', () async {
    prestage('libdisplay-info-0.2.0');
    final calls = <List<String>>[];
    final envs = <Map<String, String>?>[];
    Future<RunResult> run(
      String exe,
      List<String> args, {
      String? workingDirectory,
      Map<String, String>? environment,
      bool includeParentEnvironment = true,
      bool runInShell = false,
      ProcessOutputMode output = ProcessOutputMode.capture,
      String? label,
    }) async {
      calls.add([exe, ...args]);
      envs.add(environment);
      if (exe == 'pkg-config') return const RunResult(1, '', ''); // unmet
      return const RunResult(0, '', '');
    }

    final ob = OverlayBuilder(Workspace(tmp), _profile, runProcess: run);
    final paths = await ob.build([_lib()]);
    ob.close();

    final meson = calls.firstWhere((c) => c.first == 'meson');
    expect(meson, containsAll(['--cross-file', '/c.cross', 'static']));
    final installIdx = calls.indexWhere(
      (c) => c.first == 'ninja' && c.contains('install'),
    );
    expect(installIdx, greaterThan(-1));
    expect(envs[installIdx]!['DESTDIR'], paths.prefix);
  });

  test('builds a cmake header-only lib (G-06)', () async {
    prestage('vulkan-headers-1.4.309');
    final calls = <List<String>>[];
    Future<RunResult> run(
      String exe,
      List<String> args, {
      String? workingDirectory,
      Map<String, String>? environment,
      bool includeParentEnvironment = true,
      bool runInShell = false,
      ProcessOutputMode output = ProcessOutputMode.capture,
      String? label,
    }) async {
      calls.add([exe, ...args]);
      if (exe == 'pkg-config') return const RunResult(1, '', '');
      return const RunResult(0, '', '');
    }

    final ob = OverlayBuilder(Workspace(tmp), _profile, runProcess: run);
    await ob.build([_lib(build: 'cmake', static: false)]);
    ob.close();

    final cfg = calls.firstWhere((c) => c.first == 'cmake' && c.contains('-S'));
    expect(cfg, contains('-DCMAKE_TOOLCHAIN_FILE=/tc.cmake'));
    final inst = calls.firstWhere(
      (c) => c.first == 'cmake' && c.contains('--install'),
    );
    expect(inst.join(' '), contains('overlay-'));
  });

  test('surfaces a failed build step (G-07)', () async {
    prestage('libdisplay-info-0.2.0');
    Future<RunResult> run(
      String exe,
      List<String> args, {
      String? workingDirectory,
      Map<String, String>? environment,
      bool includeParentEnvironment = true,
      bool runInShell = false,
      ProcessOutputMode output = ProcessOutputMode.capture,
      String? label,
    }) async {
      if (exe == 'pkg-config') return const RunResult(1, '', '');
      if (exe == 'ninja' && !args.contains('install')) {
        return const RunResult(2, '', ''); // build fails
      }
      return const RunResult(0, '', '');
    }

    final ob = OverlayBuilder(Workspace(tmp), _profile, runProcess: run);
    await expectLater(
      ob.build([_lib()]),
      throwsA(isA<OverlayBuildException>()),
    );
    ob.close();
  });

  test(
    'host: true cmake builds without cross env and returns host-tools bin',
    () async {
      prestage('wayland-cxx-scanner-1.0.0');
      final calls = <List<String>>[];
      final envs = <Map<String, String>?>[];
      Future<RunResult> run(
        String exe,
        List<String> args, {
        String? workingDirectory,
        Map<String, String>? environment,
        bool includeParentEnvironment = true,
        bool runInShell = false,
        ProcessOutputMode output = ProcessOutputMode.capture,
        String? label,
      }) async {
        calls.add([exe, ...args]);
        envs.add(environment);
        return const RunResult(0, '', '');
      }

      final ob = OverlayBuilder(Workspace(tmp), _profile, runProcess: run);
      final paths = await ob.build([_hostLib()]);
      ob.close();

      // No pkg-config probe for host tools.
      expect(calls.any((c) => c.first == 'pkg-config'), isFalse);
      // cmake configure must not carry a cross toolchain file.
      final cfgIdx = calls.indexWhere(
        (c) => c.first == 'cmake' && c.contains('-S'),
      );
      expect(
        calls[cfgIdx].join(' '),
        isNot(contains('-DCMAKE_TOOLCHAIN_FILE')),
      );
      // configure and build steps pass no environment
      // (host compiler, not cross).
      expect(envs[cfgIdx], isNull);
      final buildIdx = calls.indexWhere(
        (c) => c.first == 'cmake' && c.contains('--build'),
      );
      expect(envs[buildIdx], isNull);
      // Install step uses DESTDIR pointing at the host-tools workspace dir.
      final instIdx = calls.indexWhere(
        (c) => c.first == 'cmake' && c.contains('--install'),
      );
      expect(envs[instIdx]!['DESTDIR'], contains('host-tools'));
      // binDirs advertises the host-tools bin path.
      expect(paths.binDirs, hasLength(1));
      expect(paths.binDirs.single, endsWith(p.join('usr', 'bin')));
      expect(paths.binDirs.single, contains('host-tools'));
    },
  );

  test(
    'host: true meson builds without cross file or cross env (G-08)',
    () async {
      prestage('wayland-1.0.0');
      final calls = <List<String>>[];
      final envs = <Map<String, String>?>[];
      Future<RunResult> run(
        String exe,
        List<String> args, {
        String? workingDirectory,
        Map<String, String>? environment,
        bool includeParentEnvironment = true,
        bool runInShell = false,
        ProcessOutputMode output = ProcessOutputMode.capture,
        String? label,
      }) async {
        calls.add([exe, ...args]);
        envs.add(environment);
        return const RunResult(0, '', '');
      }

      final ob = OverlayBuilder(Workspace(tmp), _profile, runProcess: run);
      final paths = await ob.build([_hostLib(build: 'meson')]);
      ob.close();

      // No pkg-config probe for host tools.
      expect(calls.any((c) => c.first == 'pkg-config'), isFalse);
      // meson setup must not carry a --cross-file.
      final setupIdx = calls.indexWhere((c) => c.first == 'meson');
      expect(calls[setupIdx].join(' '), isNot(contains('--cross-file')));
      // setup and build steps pass no environment (host compiler, not cross).
      expect(envs[setupIdx], isNull);
      final buildIdx = calls.indexWhere(
        (c) => c.first == 'ninja' && !c.contains('install'),
      );
      expect(envs[buildIdx], isNull);
      // Install step uses DESTDIR pointing at the host-tools workspace dir.
      final instIdx = calls.indexWhere(
        (c) => c.first == 'ninja' && c.contains('install'),
      );
      expect(envs[instIdx]!['DESTDIR'], contains('host-tools'));
      // binDirs advertises the host-tools bin path.
      expect(paths.binDirs, hasLength(1));
      expect(paths.binDirs.single, endsWith(p.join('usr', 'bin')));
      expect(paths.binDirs.single, contains('host-tools'));
    },
  );

  test('a failing augment patch is reported, not thrown as a crash', () async {
    // A manifest error must surface as an OverlayBuildException the command
    // already catches. Before this, PatchSeriesException propagated straight
    // out of cross_command as an uncaught exception with a stack trace.
    prestage('vulkan-headers-1.4.309');

    // A patch that cannot apply: the file it targets does not exist.
    final patch = File(p.join(tmp.path, '0001-nope.patch'))
      ..writeAsStringSync(
        'diff --git a/absent.txt b/absent.txt\n'
        '--- a/absent.txt\n'
        '+++ b/absent.txt\n'
        '@@ -1 +1 @@\n'
        '-before\n'
        '+after\n',
      );

    final lib = AugmentLib.fromMap({
      'pkg': 'vulkan-headers',
      'min': '1.4.309',
      'url': 'https://x/vulkan-headers-1.4.309.tar.gz',
      'build': 'cmake',
      'patches': [patch.path],
    });

    Future<RunResult> run(
      String exe,
      List<String> args, {
      String? workingDirectory,
      Map<String, String>? environment,
      bool includeParentEnvironment = true,
      bool runInShell = false,
      ProcessOutputMode output = ProcessOutputMode.capture,
      String? label,
    }) async {
      if (exe == 'pkg-config') return const RunResult(1, '', '');
      // The patched tree is re-unpacked (the pre-staged stamp no longer
      // matches a series with a patch), and extraction must actually produce
      // a file or the empty-tree guard throws before the patch is reached.
      // `tar -tf` is the archive probe; only `-xf` unpacks.
      if (exe == 'tar' && !args.contains('-tf')) {
        File(
          p.join(args[args.indexOf('-C') + 1], 'present.txt'),
        ).writeAsStringSync('before\n');
      }
      return const RunResult(0, '', '');
    }

    final ob = OverlayBuilder(Workspace(tmp), _profile, runProcess: run);
    await expectLater(
      ob.build([lib]),
      throwsA(
        isA<OverlayBuildException>().having(
          (e) => e.message,
          'message',
          allOf(
            // Named like every other augment failure, and carrying the
            // series diagnostic rather than replacing it.
            startsWith('vulkan-headers: '),
            contains('0001-nope.patch'),
          ),
        ),
      ),
    );
    ob.close();
  });

  test(
    'host: true tool is skipped on second build when stamp matches',
    () async {
      prestage('wayland-cxx-scanner-1.0.0');
      var buildCount = 0;
      Future<RunResult> run(
        String exe,
        List<String> args, {
        String? workingDirectory,
        Map<String, String>? environment,
        bool includeParentEnvironment = true,
        bool runInShell = false,
        ProcessOutputMode output = ProcessOutputMode.capture,
        String? label,
      }) async {
        if (exe == 'cmake' && args.contains('-S')) buildCount++;
        return const RunResult(0, '', '');
      }

      final lib = _hostLib();
      final ob = OverlayBuilder(Workspace(tmp), _profile, runProcess: run);
      await ob.build([lib]);
      ob.close();
      expect(buildCount, 1, reason: 'first build');

      // Second invocation with identical inputs: cmake must not be called
      // again.
      final ob2 = OverlayBuilder(Workspace(tmp), _profile, runProcess: run);
      await ob2.build([lib]);
      ob2.close();
      expect(
        buildCount,
        1,
        reason: 'stamp hit — cmake skipped on second build',
      );
    },
  );

  test(
    'host: true tool rebuilds when inputs change (stamp mismatch)',
    () async {
      prestage('wayland-cxx-scanner-1.0.0');
      prestage('wayland-cxx-scanner-2.0.0');
      var buildCount = 0;
      Future<RunResult> run(
        String exe,
        List<String> args, {
        String? workingDirectory,
        Map<String, String>? environment,
        bool includeParentEnvironment = true,
        bool runInShell = false,
        ProcessOutputMode output = ProcessOutputMode.capture,
        String? label,
      }) async {
        if (exe == 'cmake' && args.contains('-S')) buildCount++;
        return const RunResult(0, '', '');
      }

      final ob = OverlayBuilder(Workspace(tmp), _profile, runProcess: run);
      await ob.build([_hostLib()]);
      ob.close();
      expect(buildCount, 1);

      // Same package, different version: stamp key changes, must rebuild.
      final updated = AugmentLib.fromMap({
        'pkg': 'wayland-cxx-scanner',
        'min': '2.0.0',
        'url': 'https://x/wayland-cxx-scanner-2.0.0.tar.gz',
        'build': 'cmake',
        'host': true,
      });
      final ob2 = OverlayBuilder(Workspace(tmp), _profile, runProcess: run);
      await ob2.build([updated]);
      ob2.close();
      expect(buildCount, 2, reason: 'version changed — must rebuild');
    },
  );

  test(
    'host: true tool rebuilds when compiler version changes (stamp mismatch)',
    () async {
      prestage('wayland-cxx-scanner-1.0.0');
      var buildCount = 0;

      ProcessRunner runWith(String compilerVersion) =>
          (
            String exe,
            List<String> args, {
            String? workingDirectory,
            Map<String, String>? environment,
            bool includeParentEnvironment = true,
            bool runInShell = false,
            ProcessOutputMode output = ProcessOutputMode.capture,
            String? label,
          }) async {
            if (exe == 'cmake' && args.contains('-S')) buildCount++;
            final stdout = args.contains('--version') ? compilerVersion : '';
            return RunResult(0, stdout, '');
          };

      final lib = _hostLib();
      final ob = OverlayBuilder(
        Workspace(tmp),
        _profile,
        runProcess: runWith('gcc (Ubuntu 13.1.0) 13.1.0'),
      );
      await ob.build([lib]);
      ob.close();
      expect(buildCount, 1, reason: 'first build');

      // Same inputs, different compiler: stamp key changes, must rebuild.
      final ob2 = OverlayBuilder(
        Workspace(tmp),
        _profile,
        runProcess: runWith('gcc (Ubuntu 14.2.0) 14.2.0'),
      );
      await ob2.build([lib]);
      ob2.close();
      expect(buildCount, 2, reason: 'compiler changed — must rebuild');
    },
  );

  test('host: true stamp is cleared before build so a failed install does not '
      'leave a stale hit', () async {
    prestage('wayland-cxx-scanner-1.0.0');
    prestage('wayland-cxx-scanner-2.0.0');
    var buildCount = 0;
    var failConfigure = false;

    Future<RunResult> run(
      String exe,
      List<String> args, {
      String? workingDirectory,
      Map<String, String>? environment,
      bool includeParentEnvironment = true,
      bool runInShell = false,
      ProcessOutputMode output = ProcessOutputMode.capture,
      String? label,
    }) async {
      if (exe == 'cmake' && args.contains('-S')) {
        buildCount++;
        if (failConfigure) return const RunResult(1, '', 'simulated failure');
      }
      return const RunResult(0, '', '');
    }

    // First build: v1 succeeds, stamp written.
    final ob = OverlayBuilder(Workspace(tmp), _profile, runProcess: run);
    await ob.build([_hostLib()]);
    ob.close();
    expect(buildCount, 1);

    // Second build: v2 key doesn't match v1 stamp → stamp deleted → cmake
    // configure fails → no new stamp written.
    failConfigure = true;
    final v2 = AugmentLib.fromMap({
      'pkg': 'wayland-cxx-scanner',
      'min': '2.0.0',
      'url': 'https://x/wayland-cxx-scanner-2.0.0.tar.gz',
      'build': 'cmake',
      'host': true,
    });
    final ob2 = OverlayBuilder(Workspace(tmp), _profile, runProcess: run);
    await expectLater(ob2.build([v2]), throwsA(isA<OverlayBuildException>()));
    ob2.close();
    expect(buildCount, 2);

    // Third build: no stamp present → must rebuild, not skip.
    failConfigure = false;
    final ob3 = OverlayBuilder(Workspace(tmp), _profile, runProcess: run);
    await ob3.build([v2]);
    ob3.close();
    expect(
      buildCount,
      3,
      reason: 'stale stamp must not survive a failed build',
    );
  });

  // ---- corrupt-cache healing (_fetchSource) --------------------------------

  Future<_FakeOrigin> originWithGzip() =>
      _FakeOrigin.start(gzip.encode(utf8.encode('payload\n')));

  test(
    'corrupt (sha-less) cached tarball is re-downloaded, not patched against',
    () async {
      // The regression: a truncated cached download was trusted on
      // existsSync(), extracted to nothing (exit code ignored), and the failure
      // surfaced much later as a misleading patch error. Now the magic-byte +
      // gzip -t check rejects it before extraction, and a clean re-download
      // heals the cache.
      final origin = await originWithGzip();
      addTearDown(origin.close);
      // Point the lib at the fake origin so the re-download succeeds.
      final lib = AugmentLib.fromMap({
        'pkg': 'libdisplay-info',
        'min': '0.2.0',
        'url': '${origin.origin}/libdisplay-info-0.2.0.tar.gz',
        'build': 'meson',
      });
      final src = Directory(
        p.join(tmp.path, '.config', 'flutter_workspace', 'overlay-src'),
      )..createSync(recursive: true);
      final tarball = File(
        p.join(src.path, 'libdisplay-info-libdisplay-info-0.2.0.tar.gz'),
      )..writeAsBytesSync(List.filled(1000, 0x41)); // garbage bytes
      final runner = _StopAfterFetch();

      final ob = OverlayBuilder(
        Workspace(tmp),
        _profile,
        runProcess: runner.call,
      );
      await expectLater(ob.build([lib]), throwsA(isA<OverlayBuildException>()));
      ob.close();

      expect(
        origin.requests,
        1,
      ); // corrupt cache triggered exactly one re-fetch
      expect(tarball.readAsBytesSync(), isNot(equals(List.filled(1000, 0x41))));
      // The healed tarball is a real gzip.
      expect(tarball.readAsBytesSync().take(2), [0x1f, 0x8b]);
    },
  );

  test('cached tarball is reused when valid — no re-download', () async {
    final origin = await originWithGzip();
    addTearDown(origin.close);
    final lib = AugmentLib.fromMap({
      'pkg': 'libdisplay-info',
      'min': '0.2.0',
      'url': '${origin.origin}/libdisplay-info-0.2.0.tar.gz',
      'build': 'meson',
    });
    final src = Directory(
      p.join(tmp.path, '.config', 'flutter_workspace', 'overlay-src'),
    )..createSync(recursive: true);
    File(
      p.join(src.path, 'libdisplay-info-libdisplay-info-0.2.0.tar.gz'),
    ).writeAsBytesSync(gzip.encode(utf8.encode('cached\n')));
    final runner = _StopAfterFetch();

    final ob = OverlayBuilder(
      Workspace(tmp),
      _profile,
      runProcess: runner.call,
    );
    await expectLater(ob.build([lib]), throwsA(isA<OverlayBuildException>()));
    ob.close();

    expect(origin.requests, 0); // a valid cache must not hit the network
  });

  test('tar exit != 0 raises an accurate error and leaves no dir', () async {
    // A valid gzip that `tar` itself rejects (here: a stubbed failure) must
    // produce an error naming the tarball — not a patch error against an
    // empty tree — and must not leave a pre-created empty dir behind.
    final origin = await originWithGzip();
    addTearDown(origin.close);
    final lib = AugmentLib.fromMap({
      'pkg': 'libdisplay-info',
      'min': '0.2.0',
      'url': '${origin.origin}/libdisplay-info-0.2.0.tar.gz',
      'build': 'meson',
    });
    final runner = _StopAfterFetch(extractExit: 2);

    final ob = OverlayBuilder(
      Workspace(tmp),
      _profile,
      runProcess: runner.call,
    );
    await expectLater(
      ob.build([lib]),
      throwsA(
        isA<OverlayBuildException>().having(
          (e) => e.message,
          'message',
          allOf(
            contains('extract failed'),
            contains('libdisplay-info-0.2.0.tar.gz'),
          ),
        ),
      ),
    );
    ob.close();

    final src = Directory(
      p.join(tmp.path, '.config', 'flutter_workspace', 'overlay-src'),
    );
    expect(
      Directory(p.join(src.path, 'libdisplay-info-0.2.0')).existsSync(),
      isFalse,
    );
    expect(
      Directory(p.join(src.path, 'libdisplay-info-0.2.0.unzip')).existsSync(),
      isFalse,
    );
  });

  test('sha-pinned download mismatch should retry', () async {
    final bytes = gzip.encode(utf8.encode('wrong mirror\n'));
    final origin = await _FakeOrigin.start(bytes);
    addTearDown(origin.close);
    final lib = AugmentLib.fromMap({
      'pkg': 'libdisplay-info',
      'min': '0.2.0',
      'url': '${origin.origin}/libdisplay-info-0.2.0.tar.gz',
      'build': 'meson',
      'sha256': sha256.convert(utf8.encode('some other bytes')).toString(),
    });

    expect(lib.sha256, isNotNull);

    final runner = _StopAfterFetch();

    final ob = OverlayBuilder(
      Workspace(tmp),
      _profile,
      runProcess: runner.call,
    );
    await expectLater(
      ob.build([lib]),
      throwsA(
        isA<OverlayBuildException>().having(
          (e) => e.message,
          'message',
          contains('sha256'),
        ),
      ),
    );
    ob.close();

    expect(origin.requests, 3); // mismatch: delete, re-fetch, still bad
  });

  test('an HTML error page served as a tarball is rejected', () async {
    final origin = await _FakeOrigin.start(
      utf8.encode('<html><body>404 Not Found</body></html>'),
    );
    addTearDown(origin.close);
    final lib = AugmentLib.fromMap({
      'pkg': 'libdisplay-info',
      'min': '0.2.0',
      'url': '${origin.origin}/libdisplay-info-0.2.0.tar.gz',
      'build': 'meson',
    });
    final runner = _StopAfterFetch();

    final ob = OverlayBuilder(
      Workspace(tmp),
      _profile,
      runProcess: runner.call,
    );
    await expectLater(
      ob.build([lib]),
      throwsA(
        isA<OverlayBuildException>().having(
          (e) => e.message,
          'message',
          contains('corrupt archive data'),
        ),
      ),
    );
    ob.close();
  });

  test('a probe tool that cannot be spawned keeps the tarball', () async {
    // The bytes already passed the magic check, so the download is not the
    // problem: deleting and re-fetching it 3x would waste the bandwidth and
    // still fail. The error must name the tool, and the cache must survive so
    // installing it and building again costs nothing.
    final origin = await _FakeOrigin.start(
      gzip.encode(utf8.encode('cached\n')),
    );
    addTearDown(origin.close);
    final src = Directory(
      p.join(tmp.path, '.config', 'flutter_workspace', 'overlay-src'),
    )..createSync(recursive: true);
    final tarball = File(
      p.join(src.path, 'libdisplay-info-libdisplay-info-0.2.0.tar.gz'),
    )..writeAsBytesSync(gzip.encode(utf8.encode('cached\n')));
    final lib = AugmentLib.fromMap({
      'pkg': 'libdisplay-info',
      'min': '0.2.0',
      'url': '${origin.origin}/libdisplay-info-0.2.0.tar.gz',
      'build': 'meson',
    });

    final ob = OverlayBuilder(
      Workspace(tmp),
      _profile,
      runProcess:
          (
            exe,
            args, {
            workingDirectory,
            environment,
            includeParentEnvironment = true,
            runInShell = false,
            output = ProcessOutputMode.capture,
            label,
          }) async {
            if (exe == 'pkg-config') return const RunResult(1, '', '');
            // `tar` is absent from this host: dart:io reports that as a
            // throw, never as an exit code. `-tf` is the probe, so extraction
            // is never reached.
            if (exe == 'tar') {
              throw ProcessException(exe, args, 'No such file or directory', 2);
            }
            return const RunResult(0, '', '');
          },
    );
    await expectLater(
      ob.build([lib]),
      throwsA(
        isA<OverlayBuildException>().having(
          (e) => e.message,
          'message',
          allOf(
            contains('required command is missing'),
            contains('Could not run "tar"'),
          ),
        ),
      ),
    );
    ob.close();

    expect(tarball.existsSync(), isTrue); // fatal != bad bytes: keep them
    expect(origin.requests, 0); // and never re-fetch them
  });

  test('a space in the cache path does not split the extract argv', () async {
    // extractCmd is substituted per argv element, never by splitting a command
    // string: a workspace under "My Projects" used to hand `tar` a truncated
    // path plus a bogus extra argument.
    final root = Directory(p.join(tmp.path, 'My Projects'))
      ..createSync(recursive: true);
    final src = Directory(
      p.join(root.path, '.config', 'flutter_workspace', 'overlay-src'),
    )..createSync(recursive: true);
    final tarballPath = p.join(
      src.path,
      'libdisplay-info-libdisplay-info-0.2.0.tar.gz',
    );
    await _makeTarGz(tarballPath, entries: {'present.txt': 'payload\n'});
    final lib = AugmentLib.fromMap({
      'pkg': 'libdisplay-info',
      'min': '0.2.0',
      'url': 'https://x/libdisplay-info-0.2.0.tar.gz',
      'build': 'meson',
    });
    final runner = _StopAfterFetch();

    final ob = OverlayBuilder(
      Workspace(root),
      _profile,
      runProcess: runner.call,
    );
    await expectLater(ob.build([lib]), throwsA(isA<OverlayBuildException>()));
    ob.close();

    final extract = runner.calls.firstWhere((c) => c.first == 'tar');
    // The whole path arrives as one element, spaces and all.
    expect(extract, contains(tarballPath));
    expect(extract.any((a) => a == 'My' || a.endsWith('/My')), isFalse);
  });

  test('a zip is promoted by detected type, not by filename', () async {
    // A zipball served under a .tar.gz name (or as /tarball/<ref>, or as a
    // .jar) extracts through `unzip`, which has no --strip-components, so the
    // lone top-level directory must still be promoted. Keying that on the
    // filename left the tree one level too deep.
    final src = Directory(
      p.join(tmp.path, '.config', 'flutter_workspace', 'overlay-src'),
    )..createSync(recursive: true);
    File(p.join(src.path, 'libdisplay-info-libdisplay-info-0.2.0.tar.gz'))
    // PK\x03\x04: the name says gzip, the content says zip. Content wins.
    .writeAsBytesSync([0x50, 0x4b, 0x03, 0x04, ...List.filled(300, 0)]);
    final lib = AugmentLib.fromMap({
      'pkg': 'libdisplay-info',
      'min': '0.2.0',
      'url': 'https://x/libdisplay-info-0.2.0.tar.gz',
      'build': 'meson',
    });

    final calls = <List<String>>[];
    final ob = OverlayBuilder(
      Workspace(tmp),
      _profile,
      runProcess:
          (
            exe,
            args, {
            workingDirectory,
            environment,
            includeParentEnvironment = true,
            runInShell = false,
            output = ProcessOutputMode.capture,
            label,
          }) async {
            calls.add([exe, ...args]);
            if (exe == 'pkg-config') return const RunResult(1, '', '');
            if (exe == 'unzip' && !args.contains('-t')) {
              // Stand in for a real unzip: one top-level dir, the way
              // release zips ship.
              final dest = args[args.indexOf('-d') + 1];
              final top = Directory(p.join(dest, 'libdisplay-info-0.2.0'))
                ..createSync(recursive: true);
              File(
                p.join(top.path, 'present.txt'),
              ).writeAsStringSync('payload\n');
              return const RunResult(0, '', '');
            }
            if (exe == 'meson') return const RunResult(9, '', 'stop here');
            return const RunResult(0, '', '');
          },
    );
    await expectLater(ob.build([lib]), throwsA(isA<OverlayBuildException>()));
    ob.close();

    // Detection routed to unzip despite the .tar.gz name, and never to tar.
    expect(calls.any((c) => c.first == 'unzip'), isTrue);
    expect(calls.any((c) => c.first == 'tar'), isFalse);
    // The promotion flattened the wrapper dir: the payload sits at the root.
    final tree = Directory(p.join(src.path, 'libdisplay-info-0.2.0'));
    expect(File(p.join(tree.path, 'present.txt')).existsSync(), isTrue);
  });

  test(
    'an unrecognizable body with no extension is retried, not fatal',
    () async {
      // GitHub's /tarball/<ref> and SourceForge's /download carry no extension,
      // so an HTML rate-limit or auth page served there matches nothing.
      // That is a bad body, indistinguishable from a truncated fetch, and
      // must re-fetch
      // rather than fail on the first attempt.
      final origin = await _FakeOrigin.start(
        utf8.encode('<html><body>rate limited</body></html>'),
      );
      addTearDown(origin.close);
      final lib = AugmentLib.fromMap({
        'pkg': 'libdisplay-info',
        'min': '0.2.0',
        'url': '${origin.origin}/tarball/v0.2.0',
        'build': 'meson',
      });
      final runner = _StopAfterFetch();

      final ob = OverlayBuilder(
        Workspace(tmp),
        _profile,
        runProcess: runner.call,
      );
      await expectLater(
        ob.build([lib]),
        throwsA(
          isA<OverlayBuildException>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('unsupported archive format'),
              contains('after 3 attempts'),
            ),
          ),
        ),
      );
      ob.close();

      expect(origin.requests, 3); // retried, not rejected outright
    },
  );

  test(
    'no-patch extract still stamps, and a stamp-less dir is re-unpacked',
    () async {
      // Closes the no-patch silent-empty-build hole: with no patches the tree
      // used to be reused blindly. Now every extracted tree carries a stamp and
      // only a matching stamp grants reuse.
      final src = Directory(
        p.join(tmp.path, '.config', 'flutter_workspace', 'overlay-src'),
      )..createSync(recursive: true);
      await _makeTarGz(
        p.join(src.path, 'libdisplay-info-libdisplay-info-0.2.0.tar.gz'),
        entries: {'present.txt': 'payload\n'},
      );
      // A pre-existing, stamp-less tree (stale from an older emb, or hand-made)
      // must be replaced by a fresh extraction.
      final stale = Directory(p.join(src.path, 'libdisplay-info-0.2.0'))
        ..createSync(recursive: true);
      File(p.join(stale.path, 'stale.txt')).writeAsStringSync('stale');
      final runner = _StopAfterFetch();

      const url = 'https://x/libdisplay-info-0.2.0.tar.gz';
      final lib = AugmentLib.fromMap({
        'pkg': 'libdisplay-info',
        'min': '0.2.0',
        'url': url,
        'build': 'meson',
      });

      final ob = OverlayBuilder(
        Workspace(tmp),
        _profile,
        runProcess: runner.call,
      );
      await expectLater(ob.build([lib]), throwsA(isA<OverlayBuildException>()));
      ob.close();

      // A real `tar` was invoked against the staged tarball.
      expect(runner.calls.any((c) => c.first == 'tar'), isTrue);

      final tree = Directory(p.join(src.path, 'libdisplay-info-0.2.0'));
      expect(tree.existsSync(), isTrue);
      expect(File(p.join(tree.path, 'stale.txt')).existsSync(), isFalse);
      // The stamp is written even with an empty patch list, so the next run
      // reuses this tree.
      expect(File(p.join(tree.path, '.emb-patch-stamp')).existsSync(), isTrue);
    },
  );

  _securityAndDetection();
}

void _securityAndDetection() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('emb_overlay_sec_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  Directory srcDir() =>
      Directory(p.join(tmp.path, '.config', 'flutter_workspace', 'overlay-src'))
        ..createSync(recursive: true);

  test('a zip whose only top-level entry is a symlink is refused', () async {
    // The promotion moves a lone top-level directory up one level. listSync()
    // reports a symlink-to-directory as a Directory, so without a no-follow
    // check a hostile archive could leave the source dir a link out of the
    // cache — and the stamp write, the `_build` wipe and the configure step
    // would all follow it.
    final src = srcDir();
    final victim = Directory(p.join(tmp.path, 'victim'))
      ..createSync(recursive: true);
    File(p.join(victim.path, 'keep.txt')).writeAsStringSync('precious\n');
    File(
      p.join(src.path, 'libdisplay-info-libdisplay-info-0.2.0.zip'),
    ).writeAsBytesSync([0x50, 0x4b, 0x03, 0x04, ...List.filled(300, 0)]);
    final lib = AugmentLib.fromMap({
      'pkg': 'libdisplay-info',
      'min': '0.2.0',
      'url': 'https://x/libdisplay-info-0.2.0.zip',
      'build': 'meson',
    });

    final ob = OverlayBuilder(
      Workspace(tmp),
      _profile,
      runProcess:
          (
            exe,
            args, {
            workingDirectory,
            environment,
            includeParentEnvironment = true,
            runInShell = false,
            output = ProcessOutputMode.capture,
            label,
          }) async {
            if (exe == 'pkg-config') return const RunResult(1, '', '');
            if (exe == 'unzip' && !args.contains('-t')) {
              // What `unzip` does with a zip built by `zip --symlinks`.
              final dest = args[args.indexOf('-d') + 1];
              Link(p.join(dest, 'onlydir')).createSync(victim.path);
              return const RunResult(0, '', '');
            }
            if (exe == 'meson') return const RunResult(9, '', 'stop here');
            return const RunResult(0, '', '');
          },
    );
    await expectLater(ob.build([lib]), throwsA(isA<OverlayBuildException>()));
    ob.close();

    // The staged link was promoted as a plain entry at most: the source dir is
    // never itself a link out of the cache, and the victim keeps its files.
    final tree = p.join(src.path, 'libdisplay-info-0.2.0');
    expect(
      FileSystemEntity.typeSync(tree, followLinks: false),
      isNot(FileSystemEntityType.link),
    );
    expect(File(p.join(victim.path, 'keep.txt')).existsSync(), isTrue);
    expect(File(p.join(victim.path, '.emb-patch-stamp')).existsSync(), isFalse);
  });

  test('a recognized but unhandled format fails at once, naming it', () async {
    // 7-zip bytes under a .tar.gz name: re-fetching cannot help, so it must not
    // cost three downloads, and the message must say what arrived.
    final origin = await _FakeOrigin.start([
      0x37, 0x7a, 0xbc, 0xaf, 0x27, 0x1c, //
      ...List.filled(300, 0),
    ]);
    addTearDown(origin.close);
    final lib = AugmentLib.fromMap({
      'pkg': 'libdisplay-info',
      'min': '0.2.0',
      'url': '${origin.origin}/libdisplay-info-0.2.0.tar.gz',
      'build': 'meson',
    });
    final runner = _StopAfterFetch();

    final ob = OverlayBuilder(
      Workspace(tmp),
      _profile,
      runProcess: runner.call,
    );
    await expectLater(
      ob.build([lib]),
      throwsA(
        isA<OverlayBuildException>().having(
          (e) => e.message,
          'message',
          allOf(contains('7-zip'), contains('cannot use this download')),
        ),
      ),
    );
    ob.close();

    expect(origin.requests, 1); // fatal: fetched once, never retried
  });

  test('a probe that exits non-zero is retried, not fatal', () async {
    // The other half of the missingCmd distinction: the tool ran and refused
    // the bytes, which is a bad body and worth re-fetching.
    final origin = await _FakeOrigin.start(
      gzip.encode(utf8.encode('plausible\n')),
    );
    addTearDown(origin.close);
    final lib = AugmentLib.fromMap({
      'pkg': 'libdisplay-info',
      'min': '0.2.0',
      'url': '${origin.origin}/libdisplay-info-0.2.0.tar.gz',
      'build': 'meson',
    });

    final ob = OverlayBuilder(
      Workspace(tmp),
      _profile,
      runProcess:
          (
            exe,
            args, {
            workingDirectory,
            environment,
            includeParentEnvironment = true,
            runInShell = false,
            output = ProcessOutputMode.capture,
            label,
          }) async {
            if (exe == 'pkg-config') return const RunResult(1, '', '');
            // The probe refuses every copy.
            if (exe == 'tar' && args.contains('-tf')) {
              return const RunResult(2, '', 'tar: unexpected EOF');
            }
            return const RunResult(0, '', '');
          },
    );
    await expectLater(
      ob.build([lib]),
      throwsA(
        isA<OverlayBuildException>().having(
          (e) => e.message,
          'message',
          allOf(
            contains('failed to decompress archive'),
            contains('after 3 attempts'),
          ),
        ),
      ),
    );
    ob.close();

    expect(origin.requests, 3);
  });

  test('repointing url re-unpacks instead of reusing the old tree', () async {
    // The stamp binds the tree to the source it came from. Before it covered
    // `url`, a manifest that moved to a new tag while `min:` stayed put
    // re-downloaded the tarball and then rebuilt the *old* tree.
    final src = srcDir();
    final tree = Directory(p.join(src.path, 'libdisplay-info-0.2.0'))
      ..createSync(recursive: true);
    File(p.join(tree.path, 'old.txt')).writeAsStringSync('from the old url\n');
    File(
      p.join(tree.path, '.emb-patch-stamp'),
    ).writeAsStringSync(contentHash(['https://x/old-0.2.0.tar.gz', '', '']));
    await _makeTarGz(
      p.join(src.path, 'libdisplay-info-new-0.2.0.tar.gz'),
      entries: {'new.txt': 'from the new url\n'},
    );
    final lib = AugmentLib.fromMap({
      'pkg': 'libdisplay-info',
      'min': '0.2.0',
      'url': 'https://x/new-0.2.0.tar.gz',
      'build': 'meson',
    });
    final runner = _StopAfterFetch();

    final ob = OverlayBuilder(
      Workspace(tmp),
      _profile,
      runProcess: runner.call,
    );
    await expectLater(ob.build([lib]), throwsA(isA<OverlayBuildException>()));
    ob.close();

    // Re-extracted: the tree from the previous url is gone.
    expect(File(p.join(tree.path, 'old.txt')).existsSync(), isFalse);
    expect(
      runner.calls.any((c) => c.first == 'tar' && c.contains('-xf')),
      isTrue,
    );
  });

  test('each archive row is detected from its own magic bytes', () async {
    // Only gzip and zip were exercised before, so a wrong byte in the xz,
    // bzip2, zstd or tar row would have shipped silently. Each body carries
    // nothing but its signature: detection is all that is under test.
    final cases = <String, List<int>>{
      'xz': [0xfd, 0x37, 0x7a, 0x58, 0x5a, 0x00],
      'bz2': [0x42, 0x5a, 0x68],
      'zst': [0x28, 0xb5, 0x2f, 0xfd],
    };
    for (final entry in cases.entries) {
      final src = srcDir();
      final name = 'libdisplay-info-0.2.0.tar.${entry.key}';
      File(
        p.join(src.path, 'libdisplay-info-$name'),
      ).writeAsBytesSync([...entry.value, ...List.filled(300, 0)]);
      final lib = AugmentLib.fromMap({
        'pkg': 'libdisplay-info',
        'min': '0.2.0',
        'url': 'https://x/$name',
        'build': 'meson',
      });
      final runner = _StopAfterFetch();
      final ob = OverlayBuilder(
        Workspace(tmp),
        _profile,
        runProcess: runner.call,
      );
      await expectLater(ob.build([lib]), throwsA(isA<OverlayBuildException>()));
      ob.close();

      // Probed and extracted through tar, which reads all three codecs.
      expect(
        runner.calls.any((c) => c.first == 'tar' && c.contains('-tf')),
        isTrue,
        reason: '${entry.key} was not probed',
      );
      Directory(
        p.join(src.path, 'libdisplay-info-0.2.0'),
      ).deleteSync(recursive: true);
      File(p.join(src.path, 'libdisplay-info-$name')).deleteSync();
    }
  });

  test('an old tar with no ustar signature is probed, not deleted', () async {
    // v7/GNU tars carry no `ustar` at 257. The extension names the format, so
    // the probe gets the final say rather than the good file being deleted.
    final src = srcDir();
    final tarball = File(p.join(src.path, 'libdisplay-info-old-0.2.0.tar'))
      ..writeAsBytesSync([...utf8.encode('somefile'), ...List.filled(300, 0)]);
    final lib = AugmentLib.fromMap({
      'pkg': 'libdisplay-info',
      'min': '0.2.0',
      'url': 'https://x/old-0.2.0.tar',
      'build': 'meson',
    });
    final runner = _StopAfterFetch();

    final ob = OverlayBuilder(
      Workspace(tmp),
      _profile,
      runProcess: runner.call,
    );
    await expectLater(ob.build([lib]), throwsA(isA<OverlayBuildException>()));
    ob.close();

    expect(
      runner.calls.any((c) => c.first == 'tar' && c.contains('-tf')),
      isTrue,
    );
    expect(tarball.existsSync(), isTrue); // not discarded as corrupt
  });

  test(
    'a body shorter than any signature is corrupt, not unsupported',
    () async {
      final origin = await _FakeOrigin.start([0x1f]);
      addTearDown(origin.close);
      final lib = AugmentLib.fromMap({
        'pkg': 'libdisplay-info',
        'min': '0.2.0',
        'url': '${origin.origin}/libdisplay-info-0.2.0.tar.gz',
        'build': 'meson',
      });
      final runner = _StopAfterFetch();

      final ob = OverlayBuilder(
        Workspace(tmp),
        _profile,
        runProcess: runner.call,
      );
      await expectLater(
        ob.build([lib]),
        throwsA(
          isA<OverlayBuildException>().having(
            (e) => e.message,
            'message',
            contains('corrupt archive data'),
          ),
        ),
      );
      ob.close();
    },
  );

  test('a matching sha256 pin is accepted', () async {
    // Only a mismatch was covered, so the happy path of the pin — including
    // the case-folding — was unverified.
    final src = srcDir();
    final path = p.join(
      src.path,
      'libdisplay-info-libdisplay-info-0.2.0.tar.gz',
    );
    await _makeTarGz(path, entries: {'present.txt': 'payload\n'});
    final digest = sha256.convert(File(path).readAsBytesSync()).toString();
    final lib = AugmentLib.fromMap({
      'pkg': 'libdisplay-info',
      'min': '0.2.0',
      'url': 'https://x/libdisplay-info-0.2.0.tar.gz',
      'build': 'meson',
      'sha256': digest.toUpperCase(),
    });
    final runner = _StopAfterFetch();

    final ob = OverlayBuilder(
      Workspace(tmp),
      _profile,
      runProcess: runner.call,
    );
    // Reaches the build step, i.e. the pin was accepted and the tree unpacked.
    await expectLater(
      ob.build([lib]),
      throwsA(
        isA<OverlayBuildException>().having(
          (e) => e.message,
          'message',
          contains('meson setup'),
        ),
      ),
    );
    ob.close();
  });

  test('the project source cache is used when one is given', () async {
    // Every other test exercises the legacy <workspace>/overlay-src branch, so
    // the .cache/overlay-src layout that `emb cross` actually passes was never
    // executed.
    final project = Directory(p.join(tmp.path, 'proj'))..createSync();
    final lib = AugmentLib.fromMap({
      'pkg': 'libdisplay-info',
      'min': '0.2.0',
      'url': 'https://x/libdisplay-info-0.2.0.tar.gz',
      'build': 'meson',
    });
    final cached = Directory(p.join(project.path, '.cache', 'overlay-src'))
      ..createSync(recursive: true);
    await _makeTarGz(
      p.join(cached.path, 'libdisplay-info-libdisplay-info-0.2.0.tar.gz'),
      entries: {'present.txt': 'payload\n'},
    );
    final runner = _StopAfterFetch();

    final ob = OverlayBuilder(
      Workspace(tmp),
      _profile,
      runProcess: runner.call,
      sourceCacheDir: project,
    );
    await expectLater(ob.build([lib]), throwsA(isA<OverlayBuildException>()));
    ob.close();

    // Unpacked beside the tarball in the project cache, not in the workspace.
    expect(
      Directory(p.join(cached.path, 'libdisplay-info-0.2.0')).existsSync(),
      isTrue,
    );
  });

  test(
    'a directory squatting the tarball path fails at the rename, not a probe',
    () async {
      // The cache entry for a tarball is a file: when a directory sits at that
      // path (half-finished cache surgery, a hand-made dir), `existsSync()`
      // reports *no file*, so the archive validation never runs — there is no
      // fsError to classify and nothing to delete. The download proceeds,
      // stages a `.part` body, and `rename` onto the directory is refused
      // (EISDIR); `_download` treats that as transient, retries the fetch four
      // times — four origin hits, all wasted — and then the build fails with a
      // download error naming the source. The squatter survives untouched:
      // emb never deletes what it did not create, and the rename never
      // replaced it.
      final origin = await _FakeOrigin.start(
        gzip.encode(utf8.encode('payload\n')),
      );
      addTearDown(origin.close);
      final src = srcDir();
      final squatter = Directory(
        p.join(src.path, 'libdisplay-info-libdisplay-info-0.2.0.tar.gz'),
      )..createSync();
      final lib = AugmentLib.fromMap({
        'pkg': 'libdisplay-info',
        'min': '0.2.0',
        'url': '${origin.origin}/libdisplay-info-0.2.0.tar.gz',
        'build': 'meson',
      });
      final runner = _StopAfterFetch();

      final ob = OverlayBuilder(
        Workspace(tmp),
        _profile,
        runProcess: runner.call,
      );
      await expectLater(
        ob.build([lib]),
        throwsA(
          isA<OverlayBuildException>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('download failed'),
              contains('libdisplay-info-0.2.0.tar.gz'),
            ),
          ),
        ),
      );
      ob.close();

      // Every internal download attempt reached the origin before its rename
      // back onto the directory failed — the bytes were never the problem.
      expect(origin.requests, 4);
      // The directory was never a file, so no delete or rename touched it.
      expect(squatter.existsSync(), isTrue);
      // The `.part` staging file is cleaned up on every failed attempt.
      expect(
        File('${squatter.path}.part').existsSync(),
        isFalse,
        reason: 'a failed download must not leave a .part behind',
      );
    },
  );

  test('tar magic under a .zip filename routes to tar, not unzip', () async {
    // The opposite direction of the promoted-zip case: here the extension
    // matches zip but the bytes do not, while tar's 'ustar' at 257 does.
    // Content wins over the conflicting name, so the file is probed and
    // extracted through tar (with --strip-components=1) and `unzip` is never
    // spawned. Detection-only: no real tar structure is needed in the body.
    final src = srcDir();
    final body = Uint8List(512)..setRange(257, 262, 'ustar'.codeUnits);
    File(
      p.join(src.path, 'libdisplay-info-libdisplay-info-0.2.0.zip'),
    ).writeAsBytesSync(body);
    final lib = AugmentLib.fromMap({
      'pkg': 'libdisplay-info',
      'min': '0.2.0',
      'url': 'https://x/libdisplay-info-0.2.0.zip',
      'build': 'meson',
    });
    final runner = _StopAfterFetch();

    final ob = OverlayBuilder(
      Workspace(tmp),
      _profile,
      runProcess: runner.call,
    );
    await expectLater(ob.build([lib]), throwsA(isA<OverlayBuildException>()));
    ob.close();

    // Probed as tar despite the .zip name, and never handed to unzip.
    expect(
      runner.calls.any((c) => c.first == 'tar' && c.contains('-tf')),
      isTrue,
    );
    expect(runner.calls.any((c) => c.first == 'unzip'), isFalse);
  });

  test('a min that escapes the cache is refused before any download', () async {
    // AugmentLib.fromMap blocks `/` and `..` in `min:` by charset, but the
    // builder keeps its own guard: _assertInsideCache re-checks both the
    // tarball path and the unpacked-tree path against the cache root before
    // the download loop, so a value reaching the builder by any other route
    // still cannot aim the writes — or the recursive deletes — at the
    // developer's files. Built through the public unnamed constructor to
    // bypass the charset check and actually reach that guard. The builder
    // names the tree `<pkg>-<min>`, so a bare `../evil` would only form the
    // literal segment `x-../evil` and stay inside; the leading `/` keeps
    // `..` a real parent segment (`x-/../../evil`), which is what aims the
    // tree outside the cache root.
    final origin = await _FakeOrigin.start(
      gzip.encode(utf8.encode('payload\n')),
    );
    addTearDown(origin.close);
    final lib = AugmentLib(
      pkg: 'x',
      minVersion: '/../../evil',
      url: '${origin.origin}/t.tar.gz',
    );

    final ob = OverlayBuilder(
      Workspace(tmp),
      _profile,
      runProcess:
          (
            exe,
            args, {
            workingDirectory,
            environment,
            includeParentEnvironment = true,
            runInShell = false,
            output = ProcessOutputMode.capture,
            label,
          }) async {
            // Report the sysroot unsatisfied so the build reaches _fetchSource
            // and the guard fires there, not earlier.
            if (exe == 'pkg-config') return const RunResult(1, '', '');
            return const RunResult(0, '', '');
          },
    );
    await expectLater(
      ob.build([lib]),
      throwsA(
        isA<OverlayBuildException>().having(
          (e) => e.message,
          'message',
          contains('resolves outside the source cache'),
        ),
      ),
    );
    ob.close();

    // The guard throws before the download loop: the origin, which exists
    // only to prove no network happened, was never contacted.
    expect(origin.requests, 0);
  });

  test('current tree with a pruned tarball skips the network', () async {
    // The reuse gate asks the tree before the tarball, so a stamped tree is
    // conclusive on its own: a user who prunes tarballs to reclaim disk keeps
    // building with zero fetch. No other test deletes the tarball while a
    // stamped tree stands, so this pins the "tree first" ordering — had the
    // tarball been consulted first, its absence would have cost a download.
    final origin = await _FakeOrigin.start(
      gzip.encode(utf8.encode('payload\n')),
    );
    addTearDown(origin.close);
    final src = srcDir();
    final url = '${origin.origin}/libdisplay-info-0.2.0.tar.gz';
    // The unpacked tree, named `<pkg>-<min>`, carrying a stamp keyed to the
    // exact url below (url + empty sha pin + empty patch series). The tarball
    // itself is deliberately absent.
    final tree = Directory(p.join(src.path, 'libdisplay-info-0.2.0'))
      ..createSync(recursive: true);
    File(
      p.join(tree.path, '.emb-patch-stamp'),
    ).writeAsStringSync(contentHash([url, '', '']));
    final lib = AugmentLib.fromMap({
      'pkg': 'libdisplay-info',
      'min': '0.2.0',
      'url': url,
      'build': 'meson',
    });
    final runner = _StopAfterFetch();

    final ob = OverlayBuilder(
      Workspace(tmp),
      _profile,
      runProcess: runner.call,
    );
    // The cached tree is returned and the build proceeds to configure, where
    // the stub stops it.
    await expectLater(ob.build([lib]), throwsA(isA<OverlayBuildException>()));
    ob.close();

    expect(origin.requests, 0); // tree reuse short-circuited the download
    expect(
      runner.calls.any((c) => c.first == 'meson'),
      isTrue,
      reason: 'the stamped tree must reach the build step',
    );
  });

  test(
    'a passing augment patch is stamped and reuse skips re-patching',
    () async {
      // The happy path complement of the failing-patch test: a series that
      // applies cleanly must (1) actually rewrite the tree, (2) leave the stamp
      // behind, and (3) make the next build short-circuit at the reuse gate —
      // no re-extraction, no re-patch. Before the stamp covered the patch
      // digest, the third property did not hold at all; this pins all three.
      if (Process.runSync('git', ['--version']).exitCode != 0) {
        markTestSkipped('git not available');
        return;
      }
      final src = srcDir();
      // A real gzip tarball so archive validation passes without a download.
      // The runner stub below performs the actual extraction write, so only the
      // magic bytes matter here.
      await _makeTarGz(
        p.join(src.path, 'libdisplay-info-libdisplay-info-0.2.0.tar.gz'),
        entries: {'present.txt': 'before\n'},
      );
      // The same header format as the failing-patch test, but targeting the
      // file the extraction stub drops down (`before\n`), so git apply — run
      // with --git-dir pointed at a nonexistent path, i.e. no repository
      // required — rewrites it to `after\n`.
      final patch = File(p.join(tmp.path, '0001-fix.patch'))
        ..writeAsStringSync(
          'diff --git a/present.txt b/present.txt\n'
          '--- a/present.txt\n'
          '+++ b/present.txt\n'
          '@@ -1 +1 @@\n'
          '-before\n'
          '+after\n',
        );
      final lib = AugmentLib.fromMap({
        'pkg': 'libdisplay-info',
        'min': '0.2.0',
        'url': 'https://x/libdisplay-info-0.2.0.tar.gz',
        'build': 'meson',
        'patches': [patch.path],
      });

      // One shared call log across both builds, so the -xf count below spans
      // the first (extract + patch) and second (stamp hit) run.
      final calls = <List<String>>[];
      Future<RunResult> run(
        String exe,
        List<String> args, {
        String? workingDirectory,
        Map<String, String>? environment,
        bool includeParentEnvironment = true,
        bool runInShell = false,
        ProcessOutputMode output = ProcessOutputMode.capture,
        String? label,
      }) async {
        calls.add([exe, ...args]);
        if (exe == 'pkg-config') return const RunResult(1, '', '');
        // `tar -tf` is the probe; only `-xf` unpacks, and the stub stands in
        // for it by writing the file the patch targets into the `-C` dir.
        if (exe == 'tar' && args.contains('-tf')) {
          return const RunResult(0, '', '');
        }
        if (exe == 'tar' && args.contains('-xf')) {
          final dest = args[args.indexOf('-C') + 1];
          File(p.join(dest, 'present.txt')).writeAsStringSync('before\n');
          return const RunResult(0, '', '');
        }
        if (exe == 'meson') return const RunResult(9, '', 'stop here');
        return const RunResult(0, '', '');
      }

      final tree = Directory(p.join(src.path, 'libdisplay-info-0.2.0'));

      // First build: unpack, apply, stamp — stopping at meson, which the stub
      // always fails. The patch result must survive that failure.
      var ob = OverlayBuilder(Workspace(tmp), _profile, runProcess: run);
      await expectLater(ob.build([lib]), throwsA(isA<OverlayBuildException>()));
      ob.close();

      expect(
        File(p.join(tree.path, 'present.txt')).readAsStringSync(),
        'after\n',
        reason: 'a passing patch must rewrite the extracted tree',
      );
      expect(
        File(p.join(tree.path, '.emb-patch-stamp')).existsSync(),
        isTrue,
        reason: 'a tree whose series applied must carry the stamp',
      );

      // Second build, fresh builder: the stamp matches url + pin + patch
      // digest, so the reuse gate returns the tree as-is and the build fails
      // again at meson. Exactly one `-xf` across both runs proves the stamp
      // hit skipped both the re-extraction and the re-patch.
      ob = OverlayBuilder(Workspace(tmp), _profile, runProcess: run);
      await expectLater(ob.build([lib]), throwsA(isA<OverlayBuildException>()));
      ob.close();

      expect(
        calls.where((c) => c.first == 'tar' && c.contains('-xf')).length,
        1,
        reason: 'the second build must reuse the stamped tree, not re-unpack',
      );
    },
  );
}
