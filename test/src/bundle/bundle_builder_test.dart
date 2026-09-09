import 'dart:io';
import 'dart:typed_data';

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
    final eng = Directory(
      p.join(
        ws.path,
        '.config',
        'flutter_workspace',
        'flutter-engine',
        'bundle-release-x86_64',
      ),
    );
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
      File(
        p.join(out, 'data', 'flutter_assets', 'fonts', 'MaterialIcons.ttf'),
      ).existsSync(),
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
      File(
        p.join(out, 'data', 'flutter_assets', 'kernel_blob.bin'),
      ).existsSync(),
      isFalse,
    );
  });

  test('debug bundle assembles without libapp.so (JIT)', () {
    final s = stageInputs();
    // Remove the AOT lib and stage a debug engine bundle instead.
    File(p.join(s.app.path, 'libapp.so.release')).deleteSync();
    final eng = Directory(
      p.join(
        s.ws.path,
        '.config',
        'flutter_workspace',
        'flutter-engine',
        'bundle-debug-x86_64',
      ),
    );
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
    expect(
      File(p.join(out, 'lib', 'libflutter_engine.so')).existsSync(),
      isTrue,
    );
    expect(File(p.join(out, 'lib', 'libapp.so')).existsSync(), isFalse);
    // debug keeps kernel_blob.bin (it's what the JIT engine runs).
    expect(
      File(
        p.join(out, 'data', 'flutter_assets', 'kernel_blob.bin'),
      ).existsSync(),
      isTrue,
    );
  });

  test('maps arch token to the engine bundle dir (arm64)', () {
    final s = stageInputs();
    // Rename engine dir to the arm64 token to prove arch mapping is used.
    Directory(
      p.join(
        s.ws.path,
        '.config',
        'flutter_workspace',
        'flutter-engine',
        'bundle-release-x86_64',
      ),
    ).renameSync(
      p.join(
        s.ws.path,
        '.config',
        'flutter_workspace',
        'flutter-engine',
        'bundle-release-arm64',
      ),
    );

    final result = BundleBuilder(Workspace(s.ws)).assemble(
      appPath: s.app.path,
      mode: 'release',
      arch: 'aarch64', // → engine token arm64
      outputDir: p.join(tmp.path, 'out'),
    );
    expect(result.success, isTrue);
  });

  test('stages code assets onto the loader path', () {
    final s = stageInputs();
    // `flutter build bundle` leaves code assets under
    // flutter_assets/native_assets/<os>/. NativeAssetsManifest.json names them
    // by bare filename, so the engine resolves them through the dynamic
    // loader — they have to end up in lib/ beside libflutter_engine.so.
    final nativeAssets = Directory(
      p.join(s.app.path, 'build', 'flutter_assets', 'native_assets', 'linux'),
    )..createSync(recursive: true);
    File(p.join(nativeAssets.path, 'libfoo.so')).writeAsStringSync('FOO');

    final out = p.join(tmp.path, 'out');
    final result = BundleBuilder(Workspace(s.ws)).assemble(
      appPath: s.app.path,
      mode: 'release',
      arch: 'x86_64',
      outputDir: out,
    );

    expect(result.success, isTrue);
    expect(File(p.join(out, 'lib', 'libfoo.so')).readAsStringSync(), 'FOO');
    // The asset-side copy stays: the manifest that names it lives there too.
    expect(
      File(
        p.join(
          out,
          'data',
          'flutter_assets',
          'native_assets',
          'linux',
          'libfoo.so',
        ),
      ).existsSync(),
      isTrue,
    );
  });

  test('assembles an app with no code assets', () {
    // No native_assets/ directory at all — the common case, and it must not
    // become a failure now that the bundle looks for one.
    final s = stageInputs();
    final out = p.join(tmp.path, 'out');
    final result = BundleBuilder(Workspace(s.ws)).assemble(
      appPath: s.app.path,
      mode: 'release',
      arch: 'x86_64',
      outputDir: out,
    );
    expect(result.success, isTrue);
    expect(
      Directory(p.join(out, 'lib')).listSync().map((e) => p.basename(e.path)),
      unorderedEquals(<String>['libapp.so', 'libflutter_engine.so']),
    );
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

  group('architecture audit', () {
    /// A minimal little-endian 64-bit ELF header for [eMachine].
    Uint8List elf({int eMachine = 0x3e}) {
      final b = Uint8List(64);
      b[0] = 0x7f;
      b[1] = 0x45;
      b[2] = 0x4c;
      b[3] = 0x46;
      b[4] = 2; // 64-bit
      b[5] = 1; // little-endian
      ByteData.sublistView(b).setUint16(18, eMachine, Endian.little);
      return b;
    }

    /// Put a code asset under flutter_assets/native_assets, where a Dart build
    /// hook leaves one — the #145 path.
    void putCodeAsset(Directory app, String name, Uint8List bytes) {
      File(
          p.join(
            app.path,
            'build',
            'flutter_assets',
            'native_assets',
            'linux',
            name,
          ),
        )
        ..createSync(recursive: true)
        ..writeAsBytesSync(bytes);
    }

    // A hook that resolved a host compiler produces an x86-64 .so that loads on
    // the build machine and dies at dlopen on an arm64 device. emb cross has
    // caught this since #96; emb bundle/emb build reached the same staging code
    // and shipped it.
    test('a code asset matching the target arch is accepted', () {
      final s = stageInputs();
      putCodeAsset(s.app, 'libfluorite_core_ffi.so', elf());

      final result = BundleBuilder(Workspace(s.ws)).assemble(
        appPath: s.app.path,
        mode: 'release',
        arch: 'x86_64',
        outputDir: p.join(tmp.path, 'out'),
      );
      // The baseline for the rejection test below: same asset, right target.
      expect(result.success, isTrue, reason: result.message);
    });

    test('the same asset in an arm64 bundle is rejected', () {
      final s = stageInputs();
      putCodeAsset(s.app, 'libfluorite_core_ffi.so', elf());
      // Engine half for arm64, so the assemble gets far enough to audit.
      final eng = Directory(
        p.join(
          s.ws.path,
          '.config',
          'flutter_workspace',
          'flutter-engine',
          'bundle-release-arm64',
        ),
      );
      File(p.join(eng.path, 'data', 'icudtl.dat'))
        ..createSync(recursive: true)
        ..writeAsStringSync('ICU');
      File(p.join(eng.path, 'lib', 'libflutter_engine.so'))
        ..createSync(recursive: true)
        ..writeAsBytesSync(elf(eMachine: 0xb7));

      final result = BundleBuilder(Workspace(s.ws)).assemble(
        appPath: s.app.path,
        mode: 'release',
        arch: 'arm64',
        outputDir: p.join(tmp.path, 'out'),
      );

      expect(result.success, isFalse);
      expect(result.message, contains('libfluorite_core_ffi.so'));
      expect(result.message, contains('e_machine'));
      expect(result.message, contains('arm64'));
    });

    test('a matching code asset passes', () {
      final s = stageInputs();
      putCodeAsset(s.app, 'libok.so', elf());

      final result = BundleBuilder(Workspace(s.ws)).assemble(
        appPath: s.app.path,
        mode: 'release',
        arch: 'x86_64',
        outputDir: p.join(tmp.path, 'out'),
      );
      expect(result.success, isTrue, reason: result.message);
    });

    // The x64 spelling reaches here from EngineArtifacts.engineArch; before
    // this it mapped to no e_machine and skipped the check entirely.
    test('the x64 arch spelling is checked, not skipped', () {
      final s = stageInputs();
      putCodeAsset(s.app, 'libwrong.so', elf(eMachine: 0xb7));

      final result = BundleBuilder(Workspace(s.ws)).assemble(
        appPath: s.app.path,
        mode: 'release',
        arch: 'x64',
        outputDir: p.join(tmp.path, 'out'),
      );
      expect(result.success, isFalse);
      expect(result.message, contains('libwrong.so'));
    });

    test('non-ELF placeholders are ignored, not flagged', () {
      final s = stageInputs();
      putCodeAsset(s.app, 'notes.txt', Uint8List.fromList('hello'.codeUnits));

      final result = BundleBuilder(Workspace(s.ws)).assemble(
        appPath: s.app.path,
        mode: 'release',
        arch: 'x86_64',
        outputDir: p.join(tmp.path, 'out'),
      );
      expect(result.success, isTrue, reason: result.message);
    });
  });
}
