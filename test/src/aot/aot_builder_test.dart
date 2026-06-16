import 'dart:io';

import 'package:emb_cli/src/aot/aot_builder.dart';
import 'package:emb_cli/src/host/host_info.dart';
import 'package:emb_cli/src/workspace/workspace.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

const _host = HostInfo(
  os: HostOs.linux,
  machineArch: 'x86_64',
  archAliases: {'x86_64', 'x64', 'amd64'},
  hostType: 'fedora',
  versionId: '43',
);

/// Records every process invocation and returns success; simulates the build
/// dir + app.dill appearing after `flutter build bundle`.
class _Recorder {
  _Recorder(this.app);
  final String app;
  final List<({String exe, List<String> args})> calls = [];

  Future<int> run(
    String exe,
    List<String> args, {
    required String workingDirectory,
    Map<String, String>? environment,
  }) async {
    calls.add((exe: p.basename(exe), args: args));
    if (args.isNotEmpty && args.first == 'build') {
      // Materialise .dart_tool/flutter_build/<hash>/ as flutter would.
      Directory(p.join(app, '.dart_tool', 'flutter_build', 'abc123'))
          .createSync(recursive: true);
    }
    return 0;
  }
}

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('emb_aot_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  // Native x86_64 build: target == host, so the resolver picks the host SDK
  // cache gen_snapshot directly (no artifact/probe needed).
  AotBuilder builder(Directory ws, _Recorder rec) =>
      AotBuilder(Workspace(ws), host: _host, runProcess: rec.run);

  void writeApp(Directory app, {String name = 'myapp'}) {
    app.createSync(recursive: true);
    File(p.join(app.path, 'pubspec.yaml')).writeAsStringSync('name: $name\n');
  }

  // Create a fake new-scheme SDK cache so the builder picks dartaotruntime +
  // frontend_server_aot and finds a host gen_snapshot.
  void writeSdk(Directory ws) {
    final hostEngine = p.join(ws.path, 'flutter', 'bin', 'cache', 'artifacts',
        'engine', 'linux-x64');
    Directory(hostEngine).createSync(recursive: true);
    File(p.join(hostEngine, 'frontend_server_aot.dart.snapshot'))
        .writeAsStringSync('x');
    File(p.join(hostEngine, 'gen_snapshot')).writeAsStringSync('x');
    Directory(p.join(ws.path, 'flutter', 'bin', 'cache', 'artifacts', 'engine',
            'common', 'flutter_patched_sdk_product'))
        .createSync(recursive: true);
  }

  test('runs build → kernel snapshot → gen_snapshot per mode', () async {
    final ws = Directory(p.join(tmp.path, 'ws'))..createSync();
    final app = Directory(p.join(tmp.path, 'app'));
    writeApp(app);
    writeSdk(ws);
    final rec = _Recorder(app.path);

    final result = await builder(ws, rec).build(
      appPath: app.path,
      modes: const ['release'],
    );

    expect(result.success, isTrue);
    final exes = rec.calls.map((c) => c.exe).toList();
    expect(
      exes,
      containsAllInOrder(['flutter', 'dartaotruntime', 'gen_snapshot']),
    );

    // gen_snapshot emits the per-mode elf.
    final gen = rec.calls.firstWhere((c) => c.exe == 'gen_snapshot');
    expect(gen.args, contains('--snapshot_kind=app-aot-elf'));
    expect(gen.args, contains('--elf=libapp.so.release'));

    // kernel snapshot targets the product patched sdk for release + product vm.
    final kernel = rec.calls.firstWhere((c) => c.exe == 'dartaotruntime');
    expect(kernel.args, contains('-Ddart.vm.product=true'));
    expect(kernel.args, contains('package:myapp/main.dart'));
    expect(kernel.args.any((a) => a.contains('flutter_patched_sdk_product')),
        isTrue);
  });

  test('fails cleanly when pubspec has no name', () async {
    final ws = Directory(p.join(tmp.path, 'ws'))..createSync();
    final app = Directory(p.join(tmp.path, 'app'))..createSync();
    File(p.join(app.path, 'pubspec.yaml'))
        .writeAsStringSync('description: x\n');
    writeSdk(ws);

    final result =
        await builder(ws, _Recorder(app.path)).build(appPath: app.path);
    expect(result.success, isFalse);
  });
}
