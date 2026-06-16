import 'dart:io';

import 'package:emb_cli/src/bundle/bundle_builder.dart';
import 'package:emb_cli/src/workspace/workspace.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('emb_bundle_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  /// Stage every input the bundle needs for release/x86_64.
  ({Directory ws, Directory app}) stageInputs() {
    final ws = Directory(p.join(tmp.path, 'ws'))..createSync();
    final app = Directory(p.join(tmp.path, 'app'))..createSync();

    // App half: flutter_assets + libapp.so.release.
    final assets = Directory(p.join(app.path, 'build', 'flutter_assets'))
      ..createSync(recursive: true);
    File(p.join(assets.path, 'kernel_blob.bin')).writeAsStringSync('k');
    File(p.join(assets.path, 'fonts', 'MaterialIcons.ttf'))
      ..createSync(recursive: true)
      ..writeAsStringSync('f');
    File(p.join(app.path, 'libapp.so.release')).writeAsStringSync('APP');

    // Engine half: bundle-release-x86_64/{data/icudtl.dat,lib/libflutter_engine.so}
    final eng = Directory(p.join(ws.path, '.config', 'flutter_workspace',
        'flutter-engine', 'bundle-release-x86_64'));
    File(p.join(eng.path, 'data', 'icudtl.dat'))
      ..createSync(recursive: true)
      ..writeAsStringSync('ICU');
    File(p.join(eng.path, 'lib', 'libflutter_engine.so'))
      ..createSync(recursive: true)
      ..writeAsStringSync('ENG');

    return (ws: ws, app: app);
  }

  test('assembles the full ivi-homescreen layout', () {
    final s = stageInputs();
    final out = p.join(tmp.path, 'out');

    final result = BundleBuilder(Workspace(s.ws)).assemble(
      appPath: s.app.path,
      mode: 'release',
      arch: 'x86_64',
      outputDir: out,
    );

    expect(result.success, isTrue);
    expect(result.outputDir, out);
    expect(
      File(p.join(out, 'data', 'flutter_assets', 'fonts', 'MaterialIcons.ttf'))
          .existsSync(),
      isTrue,
    );
    expect(File(p.join(out, 'data', 'icudtl.dat')).existsSync(), isTrue);
    expect(File(p.join(out, 'lib', 'libapp.so')).readAsStringSync(), 'APP');
    expect(
      File(p.join(out, 'lib', 'libflutter_engine.so')).readAsStringSync(),
      'ENG',
    );
    // AOT (release): the JIT kernel is stripped — the app runs from libapp.so.
    expect(
      File(p.join(out, 'data', 'flutter_assets', 'kernel_blob.bin'))
          .existsSync(),
      isFalse,
    );
  });

  test('debug bundle assembles without libapp.so (JIT)', () {
    final s = stageInputs();
    // Remove the AOT lib and stage a debug engine bundle instead.
    File(p.join(s.app.path, 'libapp.so.release')).deleteSync();
    final eng = Directory(p.join(s.ws.path, '.config', 'flutter_workspace',
        'flutter-engine', 'bundle-debug-x86_64'));
    File(p.join(eng.path, 'data', 'icudtl.dat'))
      ..createSync(recursive: true)
      ..writeAsStringSync('ICU');
    File(p.join(eng.path, 'lib', 'libflutter_engine.so'))
      ..createSync(recursive: true)
      ..writeAsStringSync('ENG');

    final out = p.join(tmp.path, 'dbg');
    final result = BundleBuilder(Workspace(s.ws)).assemble(
      appPath: s.app.path,
      mode: 'debug',
      arch: 'x86_64',
      outputDir: out,
    );

    expect(result.success, isTrue);
    // flutter_assets + engine present; libapp.so absent (JIT runs kernel_blob).
    expect(File(p.join(out, 'data', 'icudtl.dat')).existsSync(), isTrue);
    expect(File(p.join(out, 'lib', 'libflutter_engine.so')).existsSync(),
        isTrue);
    expect(File(p.join(out, 'lib', 'libapp.so')).existsSync(), isFalse);
    // debug keeps kernel_blob.bin (it's what the JIT engine runs).
    expect(
      File(p.join(out, 'data', 'flutter_assets', 'kernel_blob.bin'))
          .existsSync(),
      isTrue,
    );
  });

  test('maps arch token to the engine bundle dir (arm64)', () {
    final s = stageInputs();
    // Rename engine dir to the arm64 token to prove arch mapping is used.
    Directory(p.join(s.ws.path, '.config', 'flutter_workspace',
            'flutter-engine', 'bundle-release-x86_64'))
        .renameSync(p.join(s.ws.path, '.config', 'flutter_workspace',
            'flutter-engine', 'bundle-release-arm64'));

    final result = BundleBuilder(Workspace(s.ws)).assemble(
      appPath: s.app.path,
      mode: 'release',
      arch: 'aarch64', // → engine token arm64
      outputDir: p.join(tmp.path, 'out'),
    );
    expect(result.success, isTrue);
  });

  test('reports each missing input', () {
    final ws = Directory(p.join(tmp.path, 'ws'))..createSync();
    final app = Directory(p.join(tmp.path, 'app'))..createSync();
    File(p.join(app.path, 'pubspec.yaml')).writeAsStringSync('name: x\n');

    final result = BundleBuilder(Workspace(ws)).assemble(
      appPath: app.path,
      mode: 'release',
      arch: 'x86_64',
      outputDir: p.join(tmp.path, 'out'),
    );
    expect(result.success, isFalse);
    expect(result.missing, hasLength(4)); // assets, libapp, icudtl, engine.so
  });
}
