import 'dart:io';

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

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('emb_overlay_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  /// Pre-stage the fetched tarball + unpacked dir so the builder never
  /// downloads or untars (isolating the build path).
  void prestage(String name) {
    final src = Directory(
      p.join(tmp.path, '.config', 'flutter_workspace', 'overlay-src'),
    )..createSync(recursive: true);
    File(p.join(src.path, '$name.tar.gz')).writeAsStringSync('');
    Directory(p.join(src.path, name)).createSync(recursive: true);
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
    }) async => exe == 'pkg-config'
        ? const RunResult(1, '', '') // not satisfied, so it gets built
        : const RunResult(0, '', '');

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
}
