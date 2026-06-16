import 'dart:io';

import 'package:emb_cli/src/cross/cross_profile.dart';
import 'package:emb_cli/src/cross/cross_target.dart';
import 'package:emb_cli/src/cross/overlay_builder.dart';
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
    Future<ProcessResult> run(
      String exe,
      List<String> args, {
      String? workingDirectory,
      Map<String, String>? environment,
      bool includeParentEnvironment = true,
      bool runInShell = false,
    }) async {
      calls.add([exe, ...args]);
      return ProcessResult(0, 0, '', ''); // pkg-config: satisfied
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
    Future<ProcessResult> run(
      String exe,
      List<String> args, {
      String? workingDirectory,
      Map<String, String>? environment,
      bool includeParentEnvironment = true,
      bool runInShell = false,
    }) async {
      calls.add([exe, ...args]);
      envs.add(environment);
      if (exe == 'pkg-config') return ProcessResult(0, 1, '', ''); // unmet
      return ProcessResult(0, 0, '', '');
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
    Future<ProcessResult> run(
      String exe,
      List<String> args, {
      String? workingDirectory,
      Map<String, String>? environment,
      bool includeParentEnvironment = true,
      bool runInShell = false,
    }) async {
      calls.add([exe, ...args]);
      if (exe == 'pkg-config') return ProcessResult(0, 1, '', '');
      return ProcessResult(0, 0, '', '');
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
    Future<ProcessResult> run(
      String exe,
      List<String> args, {
      String? workingDirectory,
      Map<String, String>? environment,
      bool includeParentEnvironment = true,
      bool runInShell = false,
    }) async {
      if (exe == 'pkg-config') return ProcessResult(0, 1, '', '');
      if (exe == 'ninja' && !args.contains('install')) {
        return ProcessResult(0, 2, '', ''); // build fails
      }
      return ProcessResult(0, 0, '', '');
    }

    final ob = OverlayBuilder(Workspace(tmp), _profile, runProcess: run);
    await expectLater(
      ob.build([_lib()]),
      throwsA(isA<OverlayBuildException>()),
    );
    ob.close();
  });
}
