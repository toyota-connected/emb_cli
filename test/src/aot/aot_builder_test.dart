import 'dart:io';

import 'package:emb_cli/src/aot/aot_builder.dart';
import 'package:emb_cli/src/cross/process_runner.dart';
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

const _armHost = HostInfo(
  os: HostOs.linux,
  machineArch: 'aarch64',
  archAliases: {'arm64', 'aarch64'},
  hostType: 'fedora',
  versionId: '43',
);

const _riscvHost = HostInfo(
  os: HostOs.linux,
  machineArch: 'riscv64',
  archAliases: {'riscv64'},
  hostType: 'fedora',
  versionId: '43',
);

/// Records every process invocation and returns success; simulates the build
/// dir + app.dill appearing after `flutter build bundle`.
class _Recorder {
  _Recorder(this.app);
  final String app;
  final List<({String exe, List<String> args})> calls = [];

  Future<RunResult> run(
    String exe,
    List<String> args, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool includeParentEnvironment = true,
    bool runInShell = false,
    ProcessOutputMode output = ProcessOutputMode.capture,
    String? label,
  }) async {
    calls.add((exe: p.basename(exe), args: args));
    if (args.isNotEmpty && args.first == 'build') {
      // Materialise .dart_tool/flutter_build/<hash>/ as flutter would.
      Directory(
        p.join(app, '.dart_tool', 'flutter_build', 'abc123'),
      ).createSync(recursive: true);
    }
    return const RunResult(0, '', '');
  }
}

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('emb_aot_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  // Native x86_64 build: target == host, so the resolver picks the host SDK
  // cache gen_snapshot directly (no artifact/probe needed).
  AotBuilder builder(Directory ws, _Recorder rec, {HostInfo host = _host}) =>
      AotBuilder(Workspace(ws), host: host, runProcess: rec.run);

  void writeApp(Directory app, {String name = 'myapp'}) {
    app.createSync(recursive: true);
    File(p.join(app.path, 'pubspec.yaml')).writeAsStringSync('name: $name\n');
    final dartTool = Directory(p.join(app.path, '.dart_tool'))
      ..createSync(recursive: true);
    File(
      p.join(dartTool.path, 'package_config.json'),
    ).writeAsStringSync('{"configVersion":2,"packages":[]}\n');
  }

  // Create a fake new-scheme SDK cache so the builder picks dartaotruntime +
  // frontend_server_aot and finds a host gen_snapshot. [engineDir] is the
  // host engine-artifacts dir name (`linux-x64`, `linux-arm64`, …).
  void writeSdk(Directory ws, {String engineDir = 'linux-x64'}) {
    final hostEngine = p.join(
      ws.path,
      'flutter',
      'bin',
      'cache',
      'artifacts',
      'engine',
      engineDir,
    );
    Directory(hostEngine).createSync(recursive: true);
    File(p.join(hostEngine, 'gen_snapshot')).writeAsStringSync('x');
    // The new-scheme frontend_server_aot snapshot lives in the Dart SDK and is
    // always host-arch — unlike the engine-artifacts copy, which is x64 even
    // inside the linux-arm64 bundle.
    final snapshots = p.join(
      ws.path,
      'flutter',
      'bin',
      'cache',
      'dart-sdk',
      'bin',
      'snapshots',
    );
    Directory(snapshots).createSync(recursive: true);
    File(
      p.join(snapshots, 'frontend_server_aot.dart.snapshot'),
    ).writeAsStringSync('x');
    Directory(
      p.join(
        ws.path,
        'flutter',
        'bin',
        'cache',
        'artifacts',
        'engine',
        'common',
        'flutter_patched_sdk_product',
      ),
    ).createSync(recursive: true);
  }

  test('runs build → kernel snapshot → gen_snapshot per mode', () async {
    final ws = Directory(p.join(tmp.path, 'ws'))..createSync();
    final app = Directory(p.join(tmp.path, 'app'));
    writeApp(app);
    writeSdk(ws);
    final rec = _Recorder(app.path);

    final result = await builder(
      ws,
      rec,
    ).build(appPath: app.path, modes: const ['release']);

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
    expect(
      kernel.args.any((a) => a.contains('flutter_patched_sdk_product')),
      isTrue,
    );

    // x86_64 host: frontend_server comes from the Dart SDK (host-arch). The
    // gen_snapshot call above succeeding also proves _hostEngine resolved to
    // linux-x64, where writeSdk placed it.
    final frontend = kernel.args.firstWhere(
      (a) => a.endsWith('frontend_server_aot.dart.snapshot'),
    );
    expect(frontend, contains(p.join('dart-sdk', 'bin', 'snapshots')));
  });

  // Regression: on a non-x64 host the engine-artifacts dir is e.g.
  // `linux-arm64`/`linux-riscv64` (not `linux-x64`), and its
  // frontend_server_aot snapshot is an x64 binary the host dartaotruntime can't
  // run. The builder must resolve the host engine dir from the host arch and
  // take frontend_server from the Dart SDK (host-arch).
  for (final (host, engineDir) in [
    (_armHost, 'linux-arm64'),
    (_riscvHost, 'linux-riscv64'),
  ]) {
    test('${host.machineArch} host resolves $engineDir engine + '
        'dart-sdk frontend_server', () async {
      final ws = Directory(p.join(tmp.path, 'ws'))..createSync();
      final app = Directory(p.join(tmp.path, 'app'));
      writeApp(app);
      writeSdk(ws, engineDir: engineDir);
      final rec = _Recorder(app.path);

      final result = await builder(
        ws,
        rec,
        host: host,
      ).build(appPath: app.path, modes: const ['release']);

      // Succeeds only if _hostEngine resolved to [engineDir] (gen_snapshot is
      // written there) — proving the arch-derived path fix.
      expect(result.success, isTrue);

      final kernel = rec.calls.firstWhere((c) => c.exe == 'dartaotruntime');
      final frontend = kernel.args.firstWhere(
        (a) => a.endsWith('frontend_server_aot.dart.snapshot'),
      );
      // Host-arch snapshot from the Dart SDK, not the x64 engine copy.
      expect(frontend, contains(p.join('dart-sdk', 'bin', 'snapshots')));
      expect(frontend, isNot(contains(p.join('artifacts', 'engine'))));
    });
  }

  // `flutter build bundle` defaults --target-platform to android-arm whatever
  // the host is. For an app with code assets that means the build hooks run for
  // Android, and the engine — looking itself up as linux_<arch> at runtime —
  // finds no matching entry in NativeAssetsManifest.json.
  ({String exe, List<String> args}) bundleCall(_Recorder rec) =>
      rec.calls.firstWhere(
        (c) =>
            c.args.length > 1 && c.args[0] == 'build' && c.args[1] == 'bundle',
      );

  test('AOT build targets linux for the requested arch', () async {
    final ws = Directory(p.join(tmp.path, 'ws'))..createSync();
    final app = Directory(p.join(tmp.path, 'app'));
    writeApp(app);
    writeSdk(ws);
    final rec = _Recorder(app.path);

    await builder(
      ws,
      rec,
    ).build(appPath: app.path, modes: ['release'], arch: 'arm64');

    expect(
      bundleCall(rec).args,
      containsAllInOrder(<String>['--target-platform', 'linux-arm64']),
    );
  });

  test('buildAssets targets linux for the requested arch', () async {
    final ws = Directory(p.join(tmp.path, 'ws'))..createSync();
    final app = Directory(p.join(tmp.path, 'app'));
    writeApp(app);
    writeSdk(ws);
    final rec = _Recorder(app.path);

    await builder(
      ws,
      rec,
    ).buildAssets(appPath: app.path, mode: 'debug', arch: 'x86_64');

    expect(
      bundleCall(rec).args,
      containsAllInOrder(<String>['--target-platform', 'linux-x64']),
    );
  });

  test('omits --target-platform where Flutter has no linux target', () async {
    final ws = Directory(p.join(tmp.path, 'ws'))..createSync();
    final app = Directory(p.join(tmp.path, 'app'));
    writeApp(app);
    writeSdk(ws);
    final rec = _Recorder(app.path);

    // armv7 has engine artifacts but no Flutter linux-* token; passing one
    // would be rejected, so the flag is left off rather than guessed.
    await builder(
      ws,
      rec,
    ).buildAssets(appPath: app.path, mode: 'release', arch: 'armv7hf');

    expect(bundleCall(rec).args, isNot(contains('--target-platform')));
  });

  test('fails cleanly when pubspec has no name', () async {
    final ws = Directory(p.join(tmp.path, 'ws'))..createSync();
    final app = Directory(p.join(tmp.path, 'app'))..createSync();
    File(
      p.join(app.path, 'pubspec.yaml'),
    ).writeAsStringSync('description: x\n');
    writeSdk(ws);

    final result = await builder(
      ws,
      _Recorder(app.path),
    ).build(appPath: app.path);
    expect(result.success, isFalse);
  });
}
