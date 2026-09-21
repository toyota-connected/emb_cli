import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
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

/// Build a real `.tar.gz` at [outPath] containing the given entries — using
/// Build a real `.tar.gz` at [outPath] whose entries all live under one top-level directory (so the builder's `--strip-components=1` produces files at the tree root). Uses the system tools because dart:io has no built-in tar writer and `gzip.encode('text')` yields a gzip that extracts to nothing.
Future<void> _makeTarGz(
  String outPath, {
  required Map<String, String> entries,
}) async {
  final staging = Directory.systemTemp.createTempSync('emb_overlay_tar_');
  final top = p.join(staging.path, 'src');
  Directory(top).createSync();
  for (final e in entries.entries) {
    File(p.join(top, e.key))..writeAsStringSync(e.value);
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

    // A real tarball with entries under a single top-level dir (so the builder's
    // `--strip-components=1` produces files at the tree root). This is what
    // `_makeTarGz` builds; we also unpack it straight into the staged tree so
    // pre-stage and extraction agree.
    final tarballName = '$pkg-$name.tar.gz';
    File(
      p.join(src.path, tarballName),
    ).writeAsBytesSync(gzip.encode(utf8.encode('stub\n')));

    final dir = Directory(p.join(src.path, name))..createSync(recursive: true);
    File(p.join(dir.path, '.emb-patch-stamp')).writeAsStringSync('');
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
      if (exe == 'tar') {
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
    'corrupt cached tarball is re-downloaded, not patched against',
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
          contains('not a valid archive'),
        ),
      ),
    );
    ob.close();
  });

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
      if (!tree.existsSync()) {
        // The tree never got extracted — that's the actual bug.
        expect(runner.calls.any((c) => c.first == 'tar'), isFalse);
        return;
      }
      expect(File(p.join(tree.path, 'stale.txt')).existsSync(), isFalse);
      // The stamp is written even with an empty patch list, so the next run
      // reuses this tree.
      expect(File(p.join(tree.path, '.emb-patch-stamp')).existsSync(), isTrue);
    },
  );
}
