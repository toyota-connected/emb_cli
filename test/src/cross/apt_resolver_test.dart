import 'package:emb_cli/src/cross/apt_resolver.dart';
import 'package:test/test.dart';

// A miniature Packages index: libdrm-dev -> libdrm2 -> libc6; plus a virtual
// `libegl-dev` provided by libegl1-mesa-dev; an `a | b` alternative.
const _packages = '''
Package: libdrm-dev
Filename: pool/main/libd/libdrm/libdrm-dev_2.4_arm64.deb
Depends: libdrm2 (= 2.4), libc6-dev | libc-dev

Package: libdrm2
Filename: pool/main/libd/libdrm/libdrm2_2.4_arm64.deb
Depends: libc6 (>= 2.34)

Package: libc6
Filename: pool/main/g/glibc/libc6_2.36_arm64.deb

Package: libegl1-mesa-dev
Filename: pool/main/m/mesa/libegl1-mesa-dev_22_arm64.deb
Provides: libegl-dev
Depends: libdrm2
''';

const _status = '''
Package: libc6
Status: install ok installed
Version: 2.36

Package: libc6-dev
Status: install ok installed

Package: somethingelse
Status: deinstall ok config-files
''';

void main() {
  final index = parsePackagesIndex(_packages, repoBase: 'http://repo');

  test('parses package name, filename, depends, provides', () {
    final drm = index.packages['libdrm-dev']!;
    expect(drm.filename, endsWith('libdrm-dev_2.4_arm64.deb'));
    expect(
      drm.url,
      'http://repo/pool/main/libd/libdrm/libdrm-dev_2.4_arm64.deb',
    );
    expect(drm.depends, ['libdrm2', 'libc6-dev']); // alternative reduced, ver
    expect(index.provides['libegl-dev'], 'libegl1-mesa-dev');
  });

  test('closure follows Depends and resolves virtual via Provides', () {
    final got = index.closure(['libdrm-dev', 'libegl-dev']).map((p) => p.name);
    expect(
      got,
      containsAll(['libdrm-dev', 'libdrm2', 'libc6', 'libegl1-mesa-dev']),
    );
  });

  test('already-installed packages are pruned from the closure', () {
    final installed = parseInstalled(_status);
    expect(installed, containsAll(['libc6', 'libc6-dev']));
    expect(installed, isNot(contains('somethingelse'))); // not installed

    final got = index
        .closure(['libdrm-dev'], satisfied: installed)
        .map((p) => p.name)
        .toList();
    expect(got, containsAll(['libdrm-dev', 'libdrm2']));
    expect(
      got,
      isNot(contains('libc6')),
    ); // pruned (already installed, transitive)
    expect(got, isNot(contains('libc6-dev')));
  });

  test('an explicit root is staged even if already installed', () {
    final installed = parseInstalled(_status); // libc6, libc6-dev
    // libc6 as an explicit root is staged despite dpkg marking it installed
    // (device images strip files of "installed" packages); as a transitive dep
    // it is still pruned (the test above).
    final got = index
        .closure(['libdrm-dev', 'libc6'], satisfied: installed)
        .map((p) => p.name)
        .toList();
    expect(got, contains('libc6')); // explicit root → staged
    expect(got, contains('libdrm-dev'));
  });

  test('merge keeps the first writer (repo priority)', () {
    final a = parsePackagesIndex(
      'Package: x\nFilename: a/x.deb\n',
      repoBase: 'http://a',
    );
    final b = parsePackagesIndex(
      'Package: x\nFilename: b/x.deb\n',
      repoBase: 'http://b',
    );
    a.addAll(b);
    expect(a.packages['x']!.repoBase, 'http://a');
  });

  group('aptIndexUrls', () {
    const sources = '''
# a comment
deb http://deb.debian.org/debian bookworm main contrib
deb [signed-by=/usr/share/keyrings/raspi.gpg] http://archive.raspberrypi.com/debian bookworm main
deb-src http://deb.debian.org/debian bookworm main
''';

    test('builds one Packages URL per source/component, skips deb-src', () {
      final urls = aptIndexUrls(sources, 'arm64');
      expect(urls, [
        'http://deb.debian.org/debian/dists/bookworm/main/binary-arm64/Packages.xz',
        'http://deb.debian.org/debian/dists/bookworm/contrib/binary-arm64/Packages.xz',
        'http://archive.raspberrypi.com/debian/dists/bookworm/main/binary-arm64/Packages.xz',
      ]);
    });
  });
}
