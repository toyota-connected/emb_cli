import 'dart:io';

import 'package:emb_cli/src/cross/package_files.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('emb_pkgfiles_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  String write(String rel, [String body = 'x']) {
    final f = File(p.join(tmp.path, rel))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(body);
    return f.path;
  }

  PackageFiles expand(List<PackageFileEntry> entries) =>
      expandPackageFiles(entries, modeOf: (_) => '0644');

  test('a file source passes through unchanged', () {
    final src = write('lib/libihs.so.1');
    final r = expand([(src: src, dest: '/usr/lib/libihs.so.1', mode: null)]);
    expect(r.files, {src: '/usr/lib/libihs.so.1'});
    expect(r.modes[src], '0644');
    expect(r.warnings, isEmpty);
  });

  test('a missing file source is still staged (the stager reports it)', () {
    final missing = p.join(tmp.path, 'nope.so');
    final r = expand([(src: missing, dest: '/usr/lib/nope.so', mode: null)]);
    expect(r.files, {missing: '/usr/lib/nope.so'});
    expect(r.modes, isEmpty); // no source to read a mode from
  });

  group('directory sources', () {
    // The motivating case: a Flutter bundle's data/ is hundreds of files,
    // regenerated every build, so it cannot be enumerated by hand.
    test('contributes every file, rooted at dest', () {
      write('data/icudtl.dat');
      write('data/flutter_assets/AssetManifest.bin');
      write('data/flutter_assets/fonts/MaterialIcons-Regular.otf');
      final r = expand([
        (
          src: p.join(tmp.path, 'data'),
          dest: '/usr/share/app/data',
          mode: null,
        ),
      ]);
      expect(r.files.values.toSet(), {
        '/usr/share/app/data/icudtl.dat',
        '/usr/share/app/data/flutter_assets/AssetManifest.bin',
        '/usr/share/app/data/flutter_assets/fonts/MaterialIcons-Regular.otf',
      });
      expect(r.warnings, isEmpty);
    });

    test("the entry's mode applies to every contained file", () {
      write('data/a.bin');
      write('data/sub/b.bin');
      final r = expandPackageFiles([
        (src: p.join(tmp.path, 'data'), dest: '/usr/share/app', mode: '0600'),
      ], modeOf: (_) => fail('explicit mode must win over the file mode'));
      expect(r.modes.values, everyElement('0600'));
      expect(r.modes, hasLength(2));
    });

    test('without a mode each file keeps its own', () {
      write('data/a.bin');
      final r = expandPackageFiles([
        (src: p.join(tmp.path, 'data'), dest: '/usr/share/app', mode: null),
      ], modeOf: (_) => '0755');
      expect(r.modes.values.single, '0755');
    });

    test('an empty directory contributes nothing', () {
      Directory(p.join(tmp.path, 'empty')).createSync();
      final r = expand([
        (src: p.join(tmp.path, 'empty'), dest: '/usr/share/app', mode: null),
      ]);
      expect(r.files, isEmpty);
    });
  });

  group('explicit entries win over a directory covering them', () {
    test('same file, so it can carry its own mode', () {
      write('data/a.bin');
      final secret = write('data/secret.key');
      final r = expand([
        (src: p.join(tmp.path, 'data'), dest: '/usr/share/app', mode: '0644'),
        (src: secret, dest: '/usr/share/app/secret.key', mode: '0600'),
      ]);
      expect(r.files[secret], '/usr/share/app/secret.key');
      expect(r.modes[secret], '0600', reason: 'explicit mode must survive');
      // and the sweep still contributed the rest
      expect(r.files.values, contains('/usr/share/app/a.bin'));
    });

    test('entry order does not matter', () {
      final secret = write('data/secret.key');
      final r = expand([
        (src: secret, dest: '/usr/share/app/secret.key', mode: '0600'),
        (src: p.join(tmp.path, 'data'), dest: '/usr/share/app', mode: '0644'),
      ]);
      expect(r.modes[secret], '0600');
    });

    test('a different source claiming the same dest also wins', () {
      write('data/config.toml', 'swept');
      final override = write('overrides/config.toml', 'explicit');
      final r = expand([
        (src: p.join(tmp.path, 'data'), dest: '/etc/app', mode: null),
        (src: override, dest: '/etc/app/config.toml', mode: null),
      ]);
      // Exactly one source lands on that dest, and it is the explicit one.
      final onDest = r.files.entries
          .where((e) => e.value == '/etc/app/config.toml')
          .map((e) => e.key)
          .toList();
      expect(onDest, [override]);
    });
  });

  group('symlinks', () {
    test('a symlinked file is included', () {
      final real = write('real/asset.bin');
      Directory(p.join(tmp.path, 'data')).createSync();
      Link(p.join(tmp.path, 'data', 'asset.bin')).createSync(real);
      final r = expand([
        (src: p.join(tmp.path, 'data'), dest: '/usr/share/app', mode: null),
      ]);
      expect(r.files.values, ['/usr/share/app/asset.bin']);
      expect(r.warnings, isEmpty);
    });

    test('a symlinked directory is skipped with a warning, not descended', () {
      write('real/deep/asset.bin');
      Directory(p.join(tmp.path, 'data')).createSync();
      Link(
        p.join(tmp.path, 'data', 'linked'),
      ).createSync(p.join(tmp.path, 'real'));
      final r = expand([
        (src: p.join(tmp.path, 'data'), dest: '/usr/share/app', mode: null),
      ]);
      expect(r.files, isEmpty);
      expect(r.warnings.single, contains('symlinked directory'));
    });

    test('a link cycle terminates', () {
      write('data/a.bin');
      Link(
        p.join(tmp.path, 'data', 'loop'),
      ).createSync(p.join(tmp.path, 'data'));
      final r = expand([
        (src: p.join(tmp.path, 'data'), dest: '/usr/share/app', mode: null),
      ]);
      expect(r.files.values, ['/usr/share/app/a.bin']);
    });
  });
}
