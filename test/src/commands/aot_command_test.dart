import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:emb_cli/src/aot/aot_builder.dart';
import 'package:emb_cli/src/cache/cache_dir.dart';
import 'package:emb_cli/src/commands/aot_command.dart';
import 'package:emb_cli/src/exec/container_launcher.dart';
import 'package:emb_cli/src/exec/container_reentry.dart';
import 'package:emb_cli/src/host/host_info.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

HostInfo _mac() => const HostInfo(
  os: HostOs.macos,
  machineArch: 'arm64',
  archAliases: <String>{},
  hostType: 'darwin',
  versionId: '14',
);

HostInfo _linuxX64() => const HostInfo(
  os: HostOs.linux,
  machineArch: 'x86_64',
  archAliases: <String>{},
  hostType: 'linux',
  versionId: '24.04',
);

/// One recorded [AotBuilder.build] call.
typedef _Build = ({
  String appPath,
  List<String> modes,
  String? arch,
  String? genSnapshot,
  bool? obfuscate,
  bool strip,
});

class _FakeBuilder extends AotBuilder {
  _FakeBuilder(super.workspace, {required super.host, required this.result});

  final AotResult result;
  final builds = <_Build>[];

  @override
  Future<AotResult> build({
    required String appPath,
    List<String> modes = const ['release', 'profile'],
    String? arch,
    String? genSnapshot,
    bool? obfuscate,
    bool strip = true,
    void Function(String step)? onStep,
  }) async {
    builds.add((
      appPath: appPath,
      modes: modes,
      arch: arch,
      genSnapshot: genSnapshot,
      obfuscate: obfuscate,
      strip: strip,
    ));
    return result;
  }
}

const _ok = AotResult([
  AotModeResult(mode: 'release', success: true, output: 'libapp.so.release'),
]);

/// `emb aot` wired to a recording container runner and a recording builder.
class _Harness {
  _Harness({
    HostInfo? host,
    this.containerExit = 0,
    this.toolMissing = false,
    this.result = _ok,
  }) : host = host ?? _mac() {
    tmp = Directory.systemTemp.createTempSync('emb-aot-cmd-');
    addTearDown(() => tmp.deleteSync(recursive: true));
    app = Directory(p.join(tmp.path, 'app'))..createSync();
  }

  final HostInfo host;
  final int containerExit;
  final bool toolMissing;
  final AotResult result;
  late final Directory tmp;
  late final Directory app;

  /// The runtime argv of each container launch.
  final launches = <List<String>>[];
  final builders = <_FakeBuilder>[];
  final sysroots = <String?>[];

  /// Runs `emb aot --app-path <app> -w <tmp>` plus [extra].
  Future<int?> run([List<String> extra = const [], String? appPath]) {
    final reentry = ContainerReentry(
      host: host,
      image: 'ghcr.io/x/runtime:latest',
      inContainer: false,
      launcher: ContainerLauncher(
        run: (exe, args) async {
          if (toolMissing) throw ProcessException(exe, args, 'not found', 2);
          launches.add(args);
          return ProcessResult(0, containerExit, '', '');
        },
      ),
    );
    final command = AotCommand(
      logger: Logger(level: Level.quiet),
      host: host,
      reentry: reentry,
      builderFactory: (ws, host, sysroot) {
        sysroots.add(sysroot);
        final b = _FakeBuilder(ws, host: host, result: result);
        builders.add(b);
        return b;
      },
    );
    return (CommandRunner<int>('emb', 'test')..addCommand(command)).run([
      'aot',
      '--app-path',
      appPath ?? app.path,
      '-w',
      tmp.path,
      ...extra,
    ]);
  }

  /// What the inner emb is given: everything after `emb` in the one launch.
  List<String> get embArgs {
    final argv = launches.single;
    return argv.sublist(argv.indexOf('emb') + 1);
  }

  /// The `-v` specs of the one launch.
  List<String> get volumes {
    final argv = launches.single;
    return [
      for (var i = 0; i < argv.length - 1; i++)
        if (argv[i] == '-v') argv[i + 1],
    ];
  }
}

void main() {
  group('container re-entry', () {
    test('a non-linux host routes `emb aot` through the container', () async {
      final h = _Harness();
      expect(await h.run(), ExitCode.success.code);

      expect(h.launches.single.first, 'run');
      expect(h.builders, isEmpty);
      expect(h.embArgs, [
        'aot',
        '--app-path',
        h.app.absolute.path,
        '--mode',
        'release',
        '--exec-native',
      ]);
    });

    // The container's $FLUTTER_WORKSPACE selects its own Linux Flutter SDK;
    // the host workspace would select binaries that cannot run there.
    test('-w is not forwarded', () async {
      final h = _Harness();
      await h.run();
      expect(h.embArgs, isNot(contains('-w')));
      expect(h.embArgs, isNot(contains('--workspace')));
      expect(h.embArgs, isNot(contains(h.tmp.path)));
    });

    test('mounts the workspace, the app and the cache', () async {
      final h = _Harness();
      await h.run();
      for (final dir in [
        h.tmp.path,
        h.app.absolute.path,
        ensureCacheDir().path,
      ]) {
        expect(h.volumes, contains('$dir:$dir'));
      }
    });

    test('forwards --mode and --arch', () async {
      final h = _Harness();
      await h.run([
        '--mode',
        'release',
        '--mode',
        'profile',
        '--arch',
        'arm64',
      ]);
      expect(
        h.embArgs,
        containsAllInOrder(['--mode', 'release', '--mode', 'profile']),
      );
      expect(h.embArgs, containsAllInOrder(['--arch', 'arm64']));
    });

    test('forwards no --arch when none was passed', () async {
      final h = _Harness();
      await h.run();
      expect(h.embArgs, isNot(contains('--arch')));
    });

    group('obfuscate and strip', () {
      // Unparsed means "per mode" inside the container too; either flag
      // would pin it.
      test('neither obfuscate flag when the user passed none', () async {
        final h = _Harness();
        await h.run();
        expect(h.embArgs, isNot(contains('--obfuscate')));
        expect(h.embArgs, isNot(contains('--no-obfuscate')));
        expect(h.embArgs, isNot(contains('--no-strip')));
      });

      test('--obfuscate', () async {
        final h = _Harness();
        await h.run(['--obfuscate']);
        expect(h.embArgs, contains('--obfuscate'));
        expect(h.embArgs, isNot(contains('--no-obfuscate')));
      });

      test('--no-obfuscate', () async {
        final h = _Harness();
        await h.run(['--no-obfuscate']);
        expect(h.embArgs, contains('--no-obfuscate'));
        expect(h.embArgs, isNot(contains('--obfuscate')));
      });

      test('--no-strip', () async {
        final h = _Harness();
        await h.run(['--no-strip']);
        expect(h.embArgs, contains('--no-strip'));
      });
    });

    group('--gen-snapshot and --glibc-sysroot', () {
      test('are forwarded, with their directories mounted', () async {
        final h = _Harness();
        final gen = File(p.join(h.tmp.path, 'sdk', 'bin', 'gen_snapshot'))
          ..createSync(recursive: true);
        final sysroot = Directory(p.join(h.tmp.path, 'sysroot'))..createSync();

        await h.run([
          '--gen-snapshot',
          gen.path,
          '--glibc-sysroot',
          sysroot.path,
        ]);

        expect(h.embArgs, containsAllInOrder(['--gen-snapshot', gen.path]));
        expect(
          h.embArgs,
          containsAllInOrder(['--glibc-sysroot', sysroot.path]),
        );
        expect(h.volumes, contains('${gen.parent.path}:${gen.parent.path}'));
        expect(h.volumes, contains('${sysroot.path}:${sysroot.path}'));
      });

      // The inner emb runs in the image's working directory, so a path
      // relative to this one would name nothing there.
      test('relative paths are forwarded absolute', () async {
        final h = _Harness();
        final gen = File(p.join(h.tmp.path, 'sdk', 'bin', 'gen_snapshot'))
          ..createSync(recursive: true);
        final sysroot = Directory(p.join(h.tmp.path, 'sysroot'))..createSync();
        final relGen = p.relative(gen.path);
        final relSysroot = p.relative(sysroot.path);
        expect(p.isRelative(relGen), isTrue);

        await h.run(['--gen-snapshot', relGen, '--glibc-sysroot', relSysroot]);

        expect(h.embArgs, containsAllInOrder(['--gen-snapshot', gen.path]));
        expect(
          h.embArgs,
          containsAllInOrder(['--glibc-sysroot', sysroot.path]),
        );
        expect(h.embArgs, isNot(contains(relGen)));
        expect(h.embArgs, isNot(contains(relSysroot)));
        expect(h.volumes, contains('${gen.parent.path}:${gen.parent.path}'));
      });

      test('absent when not passed', () async {
        final h = _Harness();
        await h.run();
        expect(h.embArgs, isNot(contains('--gen-snapshot')));
        expect(h.embArgs, isNot(contains('--glibc-sysroot')));
      });
    });

    test('returns the container exit code and builds nothing', () async {
      final h = _Harness(containerExit: 3);
      expect(await h.run(), 3);
      expect(h.builders, isEmpty);
    });

    test('a missing container tool is exit 127', () async {
      final h = _Harness(toolMissing: true);
      expect(await h.run(), 127);
      expect(h.builders, isEmpty);
    });
  });

  group('native', () {
    test('a linux x86_64 host builds without a container', () async {
      final h = _Harness(host: _linuxX64());
      expect(await h.run(), ExitCode.success.code);
      expect(h.launches, isEmpty);
      expect(h.builders.single.builds, hasLength(1));
    });

    // The recursion guard: this is how the inner emb is invoked.
    test('--exec-native builds without a container on any host', () async {
      final h = _Harness();
      expect(await h.run(['--exec-native']), ExitCode.success.code);
      expect(h.launches, isEmpty);
      expect(h.builders.single.builds, hasLength(1));
    });

    test('defaults: release only, stripped, obfuscation per mode', () async {
      final h = _Harness(host: _linuxX64());
      await h.run();
      final b = h.builders.single;
      expect(b.workspace.root.path, h.tmp.path);
      expect(h.sysroots, [null]);
      final build = b.builds.single;
      expect(build.appPath, h.app.path);
      expect(build.modes, ['release']);
      expect(build.arch, null);
      expect(build.genSnapshot, null);
      expect(build.obfuscate, null);
      expect(build.strip, true);
    });

    test('passes every option to the builder', () async {
      final h = _Harness(host: _linuxX64());
      await h.run([
        '--mode',
        'profile',
        '--arch',
        'arm64',
        '--gen-snapshot',
        '/sdk/gen_snapshot',
        '--glibc-sysroot',
        '/sysroot',
        '--no-strip',
        '--obfuscate',
      ]);
      expect(h.sysroots, ['/sysroot']);
      final build = h.builders.single.builds.single;
      expect(build.appPath, h.app.path);
      expect(build.modes, ['profile']);
      expect(build.arch, 'arm64');
      expect(build.genSnapshot, '/sdk/gen_snapshot');
      expect(build.obfuscate, true);
      expect(build.strip, false);
    });

    // Explicit off is not the same as unparsed: it overrides release's
    // default of on.
    test('--no-obfuscate reaches the builder as false, not null', () async {
      final h = _Harness(host: _linuxX64());
      await h.run(['--no-obfuscate']);
      expect(h.builders.single.builds.single.obfuscate, isFalse);
    });

    test('a failed mode is ExitCode.software', () async {
      final h = _Harness(
        host: _linuxX64(),
        result: const AotResult([
          AotModeResult(mode: 'release', success: false, message: 'boom'),
        ]),
      );
      expect(await h.run(), ExitCode.software.code);
    });
  });

  test('a missing app path is a usage error before anything runs', () async {
    final h = _Harness();
    final code = await h.run(const [], p.join(h.tmp.path, 'nope'));
    expect(code, ExitCode.usage.code);
    expect(h.launches, isEmpty);
    expect(h.builders, isEmpty);
  });

  test('a stray positional argument is rejected', () async {
    final h = _Harness();
    expect(() => h.run(['extra']), throwsA(isA<UsageException>()));
    expect(h.launches, isEmpty);
  });
}
