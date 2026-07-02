import 'dart:io';

import 'package:emb_cli/src/cache/cas.dart';
import 'package:emb_cli/src/cache/store.dart';
import 'package:emb_cli/src/cross/arm_gnu_cross_provider.dart';
import 'package:emb_cli/src/cross/cross_keys.dart';
import 'package:emb_cli/src/cross/cross_profile.dart';
import 'package:emb_cli/src/cross/cross_target.dart';
import 'package:emb_cli/src/host/host_info.dart';
import 'package:emb_cli/src/workspace/workspace.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

const _linux = HostInfo(
  os: HostOs.linux,
  machineArch: 'x86_64',
  archAliases: {'x86_64', 'x64', 'amd64'},
  hostType: 'fedora',
  versionId: '43',
);

const _triple = 'aarch64-none-linux-gnu';

void main() {
  late Directory tmp;
  late Directory cache;
  late Store store;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('emb_armgnu_');
    cache = Directory.systemTemp.createTempSync('emb_armgnu_cache_');
    store = Store(cache);
  });
  tearDown(() {
    tmp.deleteSync(recursive: true);
    cache.deleteSync(recursive: true);
  });

  Future<File> blob() async =>
      File(p.join(cache.path, 'blob'))..writeAsStringSync('x');

  /// Pre-populate the store so [resolve] short-circuits every download / mount
  /// / chroot step: the toolchain always, and — for an **image** sysroot — the
  /// `sysroot-base` entry (keyed by [sysrootBaseKey]). A **device** sysroot is
  /// not content-addressable, so it is pre-staged in place under the platform
  /// dir instead.
  Future<void> prestage(
    String version,
    CrossTarget target, {
    String codename = 'bookworm',
  }) async {
    await store.ensure(
      kind: 'toolchain',
      key: 'arm-gnu-toolchain-$version-x86_64-$_triple',
      fetch: blob,
      stage: (b, into) async {
        File(p.join(into.path, 'bin', '$_triple-gcc'))
          ..createSync(recursive: true)
          ..writeAsStringSync('');
      },
    );

    if (target.sysroot?.source == SysrootProvenance.image) {
      await store.ensure(
        kind: 'sysroot-base',
        key: sysrootBaseKey(target),
        fetch: blob,
        stage: (b, into) async {
          File(p.join(into.path, 'etc', 'os-release'))
            ..createSync(recursive: true)
            ..writeAsStringSync('VERSION_CODENAME=$codename\n');
        },
      );
    } else {
      File(
          p.join(
            tmp.path,
            '.config',
            'flutter_workspace',
            'cross-$_triple-${sysrootKey(target)}',
            'sysroot',
            'etc',
            'os-release',
          ),
        )
        ..createSync(recursive: true)
        ..writeAsStringSync('VERSION_CODENAME=$codename\n');
    }
  }

  Future<CrossResolveResult> resolveTarget(
    CrossTarget t, {
    HostInfo? host,
  }) async {
    final provider = ArmGnuCrossProvider(
      t,
      workspace: Workspace(tmp),
      host: host ?? _linux,
      store: store,
      cas: Cas(cache),
    );
    final r = await provider.resolve();
    provider.close();
    return r;
  }

  test('image sysroot materializes as a symlink into the store', () async {
    // The per-workspace sysroot is a symlink into the shared sysroot-base
    // store entry — the base extraction is not copied per workspace.
    final t = CrossTarget.fromMap({
      'provider': 'arm-gnu',
      'toolchain_version': '12.3.rel1',
      'image_url': 'https://example/x.img.xz',
    });
    await prestage('12.3.rel1', t);
    final r = await resolveTarget(t);
    expect(r.ok, isTrue, reason: r.message);
    final sr = p.join(
      tmp.path,
      '.config',
      'flutter_workspace',
      'cross-$_triple-${sysrootKey(t)}',
      'sysroot',
    );
    expect(FileSystemEntity.isLinkSync(sr), isTrue);
    expect(
      Link(sr).targetSync(),
      store.rootOf('sysroot-base', sysrootBaseKey(t)).absolute.path,
    );
    // The base tree (etc/os-release) resolves through the symlink.
    expect(File(p.join(sr, 'etc', 'os-release')).existsSync(), isTrue);
  });

  test('pinned: resolves a pre-staged toolchain + sysroot', () async {
    final t = CrossTarget.fromMap({
      'provider': 'arm-gnu',
      'toolchain_version': '12.3.rel1',
      'image_url': 'https://example/x.img.xz',
      'cpu_flags': ['-mcpu=cortex-a76'],
    });
    await prestage('12.3.rel1', t);
    final r = await resolveTarget(t);
    expect(r.ok, isTrue, reason: r.message);
    final pf = r.profile!;
    expect(pf.cc, endsWith('$_triple-gcc'));
    expect(pf.targetSysroot, endsWith('sysroot'));
    expect(pf.cFlags, contains('-mcpu=cortex-a76'));
    // Debian multiarch search path for crt*.o (-B) and libs (-L).
    expect(
      pf.cFlags.any(
        (f) => f.startsWith('-B') && f.contains('aarch64-linux-gnu'),
      ),
      isTrue,
    );
    expect(pf.cmakeToolchainFile, isNotNull);
  });

  test('derive: reads the sysroot codename to pick the version', () async {
    // bookworm -> 12.3.rel1; pre-stage that toolchain.
    final t = CrossTarget.fromMap({
      'provider': 'arm-gnu',
      'version_policy': 'derive',
      'cpu_flags': ['-mcpu=cortex-a53'],
      'sysroot': {'source': 'device', 'host': 'ubuntu@board'},
    });
    await prestage('12.3.rel1', t);
    final r = await resolveTarget(t);
    expect(r.ok, isTrue, reason: r.message);
    expect(r.profile!.cc, endsWith('$_triple-gcc'));
  });

  test('same toolchain across sysrootKeys downloads + extracts once', () async {
    // A tiny real toolchain tarball, nested under <dirName>/ like arm's.
    const dirName = 'arm-gnu-toolchain-12.3.rel1-x86_64-$_triple';
    Directory(
      p.join(tmp.path, 'src', dirName, 'bin'),
    ).createSync(recursive: true);
    File(
      p.join(tmp.path, 'src', dirName, 'bin', '$_triple-gcc'),
    ).writeAsStringSync('#!/bin/sh');
    final fixture = File(p.join(tmp.path, 'tc.tar.xz'));
    final tarRc = await Process.run('tar', [
      '-cJf',
      fixture.path,
      '-C',
      p.join(tmp.path, 'src'),
      dirName,
    ]);
    expect(tarRc.exitCode, 0, reason: '${tarRc.stderr}');
    final body = fixture.readAsBytesSync();

    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var hits = 0;
    server.listen((req) {
      hits++;
      req.response
        ..add(body)
        ..close();
    });
    addTearDown(() => server.close(force: true));
    final url = 'http://127.0.0.1:${server.port}/tc.tar.xz';

    CrossTarget target(String img) => CrossTarget.fromMap({
      'provider': 'arm-gnu',
      'toolchain_version': '12.3.rel1',
      'toolchain_url': url,
      'image_url': img,
    });
    final t1 = target('https://example/a.img.xz');
    final t2 = target('https://example/b.img.xz');
    expect(sysrootKey(t1), isNot(sysrootKey(t2)));

    // Pre-populate each target's sysroot-base store entry (different images →
    // different base keys) so only the toolchain download is exercised.
    for (final t in [t1, t2]) {
      await store.ensure(
        kind: 'sysroot-base',
        key: sysrootBaseKey(t),
        fetch: blob,
        stage: (b, into) async {
          File(p.join(into.path, 'etc', 'os-release'))
            ..createSync(recursive: true)
            ..writeAsStringSync('VERSION_CODENAME=bookworm\n');
        },
      );
    }

    final r1 = await resolveTarget(t1);
    final r2 = await resolveTarget(t2);
    expect(r1.ok, isTrue, reason: r1.message);
    expect(r2.ok, isTrue, reason: r2.message);
    // Downloaded once and shared: the second sysrootKey is a store hit.
    expect(hits, 1);

    final tc = store.list().where((e) => e.kind == 'toolchain').toList();
    expect(tc, hasLength(1));
    expect(tc.single.liveRefs, 2);

    // Each workspace platform dir holds a symlink into the one store entry.
    for (final t in [t1, t2]) {
      final link = p.join(
        tmp.path,
        '.config',
        'flutter_workspace',
        'cross-$_triple-${sysrootKey(t)}',
        'toolchain',
        dirName,
      );
      expect(FileSystemEntity.isLinkSync(link), isTrue);
      expect(
        Link(link).targetSync(),
        store.rootOf('toolchain', dirName).absolute.path,
      );
    }
  });

  test(
    'sysroot base is shared across targets differing only in augments',
    () async {
      CrossTarget withAug(String pkg) => CrossTarget.fromMap({
        'provider': 'arm-gnu',
        'toolchain_version': '12.3.rel1',
        'image_url': 'https://example/x.img.xz',
        'augment': [
          {
            'pkg': pkg,
            'min': '1.0',
            'url': 'https://x/$pkg.tar.gz',
            'build': 'meson',
          },
        ],
      });
      final a = withAug('liba');
      final b = withAug('libb');
      // Different augments → different full key + platform dir, SAME base key.
      expect(sysrootBaseKey(a), sysrootBaseKey(b));
      expect(sysrootKey(a), isNot(sysrootKey(b)));

      await prestage('12.3.rel1', a);
      await prestage('12.3.rel1', b); // toolchain + base are store fast-paths

      expect((await resolveTarget(a)).ok, isTrue);
      expect((await resolveTarget(b)).ok, isTrue);

      // One shared sysroot-base extraction, referenced by both platform dirs.
      final base = store.list().where((e) => e.kind == 'sysroot-base').toList();
      expect(base, hasLength(1));
      expect(base.single.liveRefs, 2);
      for (final t in [a, b]) {
        final sr = p.join(
          tmp.path,
          '.config',
          'flutter_workspace',
          'cross-$_triple-${sysrootKey(t)}',
          'sysroot',
        );
        expect(
          Link(sr).targetSync(),
          store.rootOf('sysroot-base', sysrootBaseKey(t)).absolute.path,
        );
      }
    },
  );

  test('unavailable on a non-Linux host', () async {
    const mac = HostInfo(
      os: HostOs.macos,
      machineArch: 'arm64',
      archAliases: {'arm64'},
      hostType: 'macos',
      versionId: '14',
    );
    final r = await resolveTarget(
      CrossTarget.fromMap({'provider': 'arm-gnu'}),
      host: mac,
    );
    expect(r.status, CrossResolveStatus.unavailable);
  });

  test('unavailable when no toolchain version can be determined', () async {
    final r = await resolveTarget(
      CrossTarget.fromMap({
        'provider': 'arm-gnu',
        'image_url': 'https://example/x.img.xz',
      }),
    );
    expect(r.status, CrossResolveStatus.unavailable);
  });

  // Bug #4: an absolute multiarch symlink must be rebased *within the sysroot*,
  // not relativized from the host filesystem root.
  test('relativizeSysrootSymlinks rebases absolute links into the sysroot', () {
    const ma = 'aarch64-linux-gnu';
    final sysroot = Directory(p.join(tmp.path, 'sysroot'));
    final libdir = Directory(p.join(sysroot.path, 'usr', 'lib', ma))
      ..createSync(recursive: true);
    final realLib = File(p.join(sysroot.path, 'lib', ma, 'libc.so.6'))
      ..createSync(recursive: true)
      ..writeAsStringSync('');
    // The kind of absolute symlink a Debian rootfs ships.
    Link(p.join(libdir.path, 'libc.so')).createSync('/lib/$ma/libc.so.6');

    relativizeSysrootSymlinks(sysroot, libdir);

    final tgt = Link(p.join(libdir.path, 'libc.so')).targetSync();
    expect(p.isRelative(tgt), isTrue, reason: 'should be relative, got $tgt');
    // It must resolve to the real lib inside the sysroot (not escape to host).
    final resolved = p.normalize(p.join(libdir.path, tgt));
    expect(resolved, realLib.path);
    expect(File(resolved).existsSync(), isTrue);
  });
}
