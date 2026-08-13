import 'package:emb_cli/src/cross/apk_index.dart';
import 'package:test/test.dart';

const _fixture = '''
P:musl
V:1.2.5-r0
A:aarch64
p:so:libc.musl-aarch64.so.1=1

P:musl-dev
V:1.2.5-r0
A:aarch64
D:musl=1.2.5-r0

P:wayland-libs-client
V:1.23.0-r0
A:aarch64
p:pc:wayland-client=1.23.0

P:wayland-dev
V:1.23.0-r0
A:aarch64
D:wayland-libs-client pc:wayland-client so:libc.musl-aarch64.so.1 !bad-conflict
''';

void main() {
  final index = parseApkIndex(
    _fixture,
    repoBase: 'https://m/edge/main/aarch64',
  );

  group('parseApkIndex', () {
    test('reads records, versions, and the .apk url', () {
      expect(index.packages.keys, containsAll(<String>['musl', 'wayland-dev']));
      expect(index.packages['musl']!.version, '1.2.5-r0');
      expect(
        index.packages['musl']!.url,
        'https://m/edge/main/aarch64/musl-1.2.5-r0.apk',
      );
    });

    test('strips version constraints from deps and skips !conflicts', () {
      expect(index.packages['musl-dev']!.depends, ['musl']);
      final wl = index.packages['wayland-dev']!.depends;
      expect(wl, contains('wayland-libs-client'));
      expect(wl, contains('pc:wayland-client'));
      expect(wl, contains('so:libc.musl-aarch64.so.1'));
      expect(wl, isNot(contains('bad-conflict')));
    });

    test('registers provides (self, so:, pc:)', () {
      expect(index.provides['so:libc.musl-aarch64.so.1'], 'musl');
      expect(index.provides['pc:wayland-client'], 'wayland-libs-client');
      expect(index.provides['musl'], 'musl');
    });
  });

  group('closure', () {
    test('resolves transitive deps and virtual providers', () {
      final names = index
          .closure(['musl-dev', 'wayland-dev'])
          .map((p) => p.name)
          .toSet();
      expect(names, {'musl-dev', 'musl', 'wayland-dev', 'wayland-libs-client'});
    });

    test('honors the satisfied set for transitive deps', () {
      final names = index
          .closure(['wayland-dev'], satisfied: {'wayland-libs-client'})
          .map((p) => p.name)
          .toSet();
      expect(names, isNot(contains('wayland-libs-client')));
      expect(names, contains('wayland-dev'));
    });
  });
}
