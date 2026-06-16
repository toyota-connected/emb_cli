import 'dart:io';

import 'package:emb_cli/src/manifest/manifest_loader.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  const loader = ManifestLoader();
  setUp(() => tmp = Directory.systemTemp.createTempSync('emb_bc_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('parses the build: block from emb.yaml', () {
    final pkg = Directory(p.join(tmp.path, 'app'))..createSync();
    File(p.join(pkg.path, 'emb.yaml')).writeAsStringSync('''
id: myapp
type: app
build:
  app_path: .
  archs: [arm64, x86_64]
  modes: [release, debug]
  output: bundles
''');
    final m = loader.loadPackageDir(pkg);
    expect(m, isNotNull);
    final b = m!.build;
    expect(b, isNotNull);
    expect(b!.appPath, '.');
    expect(b.archs, ['arm64', 'x86_64']);
    expect(b.modes, ['release', 'debug']);
    expect(b.output, 'bundles');
  });

  test('build defaults: app_path "." and release mode', () {
    final pkg = Directory(p.join(tmp.path, 'app'))..createSync();
    File(p.join(pkg.path, 'emb.yaml')).writeAsStringSync('''
id: myapp
build: {}
''');
    final b = loader.loadPackageDir(pkg)!.build!;
    expect(b.appPath, '.');
    expect(b.archs, isEmpty); // → host arch at build time
    expect(b.modes, ['release']);
    expect(b.output, isNull);
  });

  test('no build: block → null', () {
    final pkg = Directory(p.join(tmp.path, 'app'))..createSync();
    File(p.join(pkg.path, 'emb.yaml')).writeAsStringSync('id: x\ntype: app\n');
    expect(loader.loadPackageDir(pkg)!.build, isNull);
  });
}
