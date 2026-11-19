import 'dart:io';

import 'package:emb_cli/src/aot/aot_builder.dart';
import 'package:emb_cli/src/bundle/bundle_builder.dart';
import 'package:emb_cli/src/bundle/bundle_pipeline.dart';
import 'package:emb_cli/src/engine/engine_artifacts.dart';
import 'package:emb_cli/src/workspace/workspace.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// An engine whose fetch fails with [message] and stages nothing.
class _NoEngine extends EngineArtifacts {
  _NoEngine(super.workspace, this.message);
  final String message;
  int fetches = 0;

  @override
  Future<EngineFetchResult> fetch({
    required String runtime,
    required String arch,
    required String commit,
    bool clean = false,
  }) async {
    fetches++;
    return EngineFetchResult(
      runtime: runtime,
      arch: arch,
      status: EngineFetchStatus.unavailable,
      message: message,
    );
  }
}

void main() {
  late Directory tmp;
  late Workspace ws;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('emb_pipeline_');
    ws = Workspace(Directory(p.join(tmp.path, 'ws'))..createSync());
    // An SDK, so there is an engine commit to fetch for.
    File(p.join(ws.flutterDir.path, 'bin', 'internal', 'engine.version'))
      ..createSync(recursive: true)
      ..writeAsStringSync('abc123\n');
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  Future<BundleResult> run(EngineArtifacts engine) => buildAndAssemble(
    workspace: ws,
    aot: AotBuilder(ws),
    bundle: BundleBuilder(ws),
    engine: engine,
    appPath: p.join(tmp.path, 'app'),
    arch: 'x86_64',
    mode: 'release',
    outputDir: p.join(tmp.path, 'out'),
    build: false,
  );

  // An offline build reaches this with the engine not cached. The fetch
  // knows that; the steps after it would only report files it left missing.
  test('a failed engine fetch with nothing staged ends the build with its '
      'reason', () async {
    final engine = _NoEngine(ws, 'offline: the engine SDK is not cached');
    final r = await run(engine);
    expect(engine.fetches, 1);
    expect(r.success, isFalse);
    expect(r.message, 'offline: the engine SDK is not cached');
  });

  // A locally built engine has no stamp, so a fetch is attempted, and there
  // may be no prebuilt for it. It still serves.
  test('a failed engine fetch does not stop a build with an engine staged by '
      'hand', () async {
    final staged = BundleBuilder(ws).engineBundleDir('release', 'x86_64');
    File(p.join(staged.path, 'data', 'icudtl.dat'))
      ..createSync(recursive: true)
      ..writeAsStringSync('ICU');
    final engine = _NoEngine(ws, 'No published prebuilt');
    final r = await run(engine);
    expect(engine.fetches, 1);
    // It goes on to assembly, which reports what the app still lacks.
    expect(r.message, isNull);
    expect(r.missing, isNotEmpty);
  });
}
