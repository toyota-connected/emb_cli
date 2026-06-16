import 'dart:io';

import 'package:emb_cli/src/host/host_info.dart';
import 'package:emb_cli/src/manifest/emb_manifest.dart';
import 'package:emb_cli/src/manifest/manifest_loader.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  const loader = ManifestLoader();

  setUp(() => tmp = Directory.systemTemp.createTempSync('emb_test_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  const fedora = HostInfo(
    os: HostOs.linux,
    machineArch: 'x86_64',
    archAliases: {'x86_64', 'x64', 'amd64'},
    hostType: 'fedora',
    versionId: '43',
  );

  test('loads legacy JSON config dir, skipping globals.json', () {
    File(p.join(tmp.path, 'globals.json')).writeAsStringSync('{"x":1}');
    File(p.join(tmp.path, 'comp.json')).writeAsStringSync('''
{
  "id": "comp",
  "type": "dependency",
  "supported_archs": ["x86_64"],
  "supported_host_types": ["fedora", "ubuntu"],
  "runtime": {
    "pre-requisites": {
      "x86_64": {
        "fedora": { "cmds": ["sudo dnf -y install freetype-devel git"] }
      }
    }
  }
}
''');
    final manifests = loader.loadConfigDir(tmp);
    expect(manifests, hasLength(1));
    final m = manifests.single;
    expect(m.id, 'comp');
    expect(m.type, 'dependency');
    expect(m.deps.resolve(fedora), containsAll(['freetype-devel', 'git']));
  });

  test('loads a self-describing emb.yaml package', () {
    final pkg = Directory(p.join(tmp.path, 'mypkg'))..createSync();
    File(p.join(pkg.path, 'emb.yaml')).writeAsStringSync('''
id: mypkg
type: app
deps:
  linux:
    fedora: [pkg-config, freetype-devel]
''');
    final m = loader.loadPackageDir(pkg);
    expect(m, isNotNull);
    expect(m!.id, 'mypkg');
    expect(m.deps.resolve(fedora), ['pkg-config', 'freetype-devel']);
  });

  test(
    'loads an emb: key from pubspec.yaml, defaulting id to package name',
    () {
      final pkg = Directory(p.join(tmp.path, 'pkgb'))..createSync();
      File(p.join(pkg.path, 'pubspec.yaml')).writeAsStringSync('''
name: pkgb
environment:
  sdk: ^3.4.0
emb:
  type: app
  deps:
    linux:
      fedora: [cmake]
''');
      final m = loader.loadPackageDir(pkg);
      expect(m, isNotNull);
      expect(m!.id, 'pkgb');
      expect(m.deps.resolve(fedora), ['cmake']);
    },
  );

  test('discoverPackages finds manifests in subdirectories', () {
    final a = Directory(p.join(tmp.path, 'a'))..createSync();
    File(p.join(a.path, 'emb.yaml')).writeAsStringSync('id: a\ntype: app\n');
    Directory(p.join(tmp.path, 'b')).createSync(); // no manifest
    final found = loader.discoverPackages(tmp);
    expect(found.map((m) => m.id), ['a']);
  });

  test('skips malformed JSON without throwing', () {
    File(p.join(tmp.path, 'bad.json')).writeAsStringSync('{not valid');
    expect(loader.loadConfigDir(tmp), isEmpty);
  });

  group('select (load + enable/disable)', () {
    EmbManifest mk(String id, {Object? load}) => EmbManifest.fromMap(
      <String, dynamic>{'id': id, if (load != null) 'load': load},
    );

    test('defaults to only load:true manifests', () {
      final ms = [mk('a'), mk('b', load: false), mk('c', load: true)];
      expect(loader.select(ms).map((m) => m.id), ['a', 'c']);
    });

    test('--enable forces a load:false component on', () {
      final ms = [mk('a', load: false), mk('b', load: false)];
      expect(loader.select(ms, enable: {'a'}).map((m) => m.id), ['a']);
    });

    test('--disable forces a load:true component off', () {
      final ms = [mk('a'), mk('b')];
      expect(loader.select(ms, disable: {'a'}).map((m) => m.id), ['b']);
    });

    test('enable wins when an id is both enabled and disabled', () {
      final ms = [mk('a', load: false)];
      final got = loader.select(ms, enable: {'a'}, disable: {'a'});
      expect(got.map((m) => m.id), ['a']);
    });

    test('unmatched enable/disable ids are ignored', () {
      final ms = [mk('a'), mk('b', load: false)];
      final got = loader.select(ms, enable: {'nope'}, disable: {'ghost'});
      expect(got.map((m) => m.id), ['a']);
    });

    test('preserves occurrence order', () {
      final ms = [mk('z'), mk('a'), mk('m')];
      expect(loader.select(ms).map((m) => m.id), ['z', 'a', 'm']);
    });
  });

  group('load truthiness', () {
    bool loadOf(Object? v) =>
        EmbManifest.fromMap(<String, dynamic>{'id': 'x', 'load': v}).load;

    test('absent load defaults to true', () {
      expect(EmbManifest.fromMap(<String, dynamic>{'id': 'x'}).load, isTrue);
    });

    test('only explicit false-y values turn a component off', () {
      expect(loadOf(false), isFalse);
      expect(loadOf('false'), isFalse);
      expect(loadOf('off'), isFalse);
      expect(loadOf(0), isFalse);
      expect(loadOf(''), isFalse);
      expect(loadOf(true), isTrue);
      expect(loadOf('true'), isTrue);
      expect(loadOf(1), isTrue);
    });
  });
}
