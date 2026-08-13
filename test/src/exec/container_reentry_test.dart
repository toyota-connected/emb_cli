import 'dart:io';

import 'package:emb_cli/src/exec/container_launcher.dart';
import 'package:emb_cli/src/exec/container_reentry.dart';
import 'package:emb_cli/src/host/host_info.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

HostInfo _host(HostOs os, String arch) => HostInfo(
  os: os,
  machineArch: arch,
  archAliases: const {},
  hostType: os.name,
  versionId: '1',
);

ContainerLauncher _fakeLauncher(void Function(String, List<String>) capture) =>
    ContainerLauncher(
      run: (exe, args, {environment}) async {
        capture(exe, args);
        return ProcessResult(0, 0, '', '');
      },
    );

void main() {
  test('linux x86_64 host runs native (null)', () async {
    var launched = false;
    final r = ContainerReentry(
      host: _host(HostOs.linux, 'x86_64'),
      launcher: _fakeLauncher((_, _) => launched = true),
      image: 'img',
    );
    final code = await r.maybeRun(embArgs: const ['aot'], mounts: const []);
    expect(code, isNull);
    expect(launched, isFalse);
  });

  test('macOS host routes and returns the inner exit code', () async {
    String? seenTool;
    List<String>? seenArgs;
    final r = ContainerReentry(
      host: _host(HostOs.macos, 'arm64'),
      launcher: ContainerLauncher(
        tool: 'podman',
        run: (exe, args, {environment}) async {
          seenTool = exe;
          seenArgs = args;
          return ProcessResult(0, 3, '', '');
        },
      ),
      image: 'ghcr.io/x/runtime:latest',
    );
    final code = await r.maybeRun(
      embArgs: const ['bundle', '--app-path', '/w/app'],
      mounts: const [Mount('/w')],
      workdir: '/w',
    );
    expect(code, 3);
    expect(seenTool, 'podman');
    expect(seenArgs, contains('ghcr.io/x/runtime:latest'));
    expect(seenArgs!.last, '--exec-native');
  });

  test('forceNative and inContainer short-circuit to native', () async {
    final mac = ContainerReentry(
      host: _host(HostOs.macos, 'arm64'),
      launcher: _fakeLauncher((_, _) {}),
      image: 'img',
    );
    expect(
      await mac.maybeRun(
        embArgs: const ['aot'],
        mounts: const [],
        forceNative: true,
      ),
      isNull,
    );

    final inContainer = ContainerReentry(
      host: _host(HostOs.macos, 'arm64'),
      launcher: _fakeLauncher((_, _) {}),
      image: 'img',
      inContainer: true,
    );
    expect(
      await inContainer.maybeRun(embArgs: const ['aot'], mounts: const []),
      isNull,
    );
  });

  test('mountsFor keeps existing dirs, dedups, drops nulls/missing', () {
    final tmp = Directory.systemTemp.createTempSync('emb-reentry-mounts-');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final a = Directory(p.join(tmp.path, 'a'))..createSync();
    final missing = p.join(tmp.path, 'nope');
    final mounts = ContainerReentry.mountsFor([
      a.path,
      a.path, // dup
      missing, // does not exist
      null,
    ]);
    expect(mounts.map((m) => m.path), [a.absolute.path]);
  });
}
