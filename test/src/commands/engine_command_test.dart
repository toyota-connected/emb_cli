import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:emb_cli/src/cache/cache_dir.dart';
import 'package:emb_cli/src/commands/engine_command.dart';
import 'package:emb_cli/src/engine/engine_artifacts.dart';
import 'package:emb_cli/src/engine/engine_builder.dart';
import 'package:emb_cli/src/engine/engine_toolchain.dart';
import 'package:emb_cli/src/exec/container_launcher.dart';
import 'package:emb_cli/src/host/host_info.dart';
import 'package:emb_cli/src/verbosity.dart';
import 'package:emb_cli/src/workspace/workspace.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:mocktail/mocktail.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

const _commit = 'abc123';

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

class _MockLogger extends Mock implements Logger {}

class _MockProgress extends Mock implements Progress {}

/// An engine source whose every fetch ends in [status].
class _FakeEngine extends EngineArtifacts {
  _FakeEngine(super.workspace, this.status, {required this.published});

  final EngineFetchStatus status;
  final bool published;
  final fetches =
      <({String runtime, String arch, String commit, bool clean})>[];
  final probes = <String>[];
  bool closed = false;

  @override
  Future<bool> isAvailable(String runtime, String arch, String commit) async {
    probes.add(runtime);
    return published;
  }

  @override
  Future<EngineFetchResult> fetch({
    required String runtime,
    required String arch,
    required String commit,
    bool clean = false,
  }) async {
    fetches.add((runtime: runtime, arch: arch, commit: commit, clean: clean));
    return EngineFetchResult(
      runtime: runtime,
      arch: arch,
      status: status,
      bundleDir: '/store/$runtime',
      message: 'fetch said no',
    );
  }

  @override
  void close() {
    closed = true;
    super.close();
  }
}

/// One recorded native build.
typedef _Build = ({
  String commit,
  String arch,
  String mode,
  ToolchainProfile profile,
  bool offline,
  bool strict,
});

/// `emb engine` wired to a fake engine source, a recording container runner
/// and a recording native build.
class _Harness {
  _Harness({
    HostInfo? host,
    this.fetch = EngineFetchStatus.unavailable,
    this.published = false,
    this.containerExit = 0,
    this.toolMissing = false,
    this.build = const EngineBuildResult(EngineBuildStatus.cached),
  }) : host = host ?? _mac() {
    tmp = Directory.systemTemp.createTempSync('emb-engine-cmd-');
    addTearDown(() => tmp.deleteSync(recursive: true));

    when(() => logger.progress(any())).thenAnswer((i) {
      started.add(i.positionalArguments.single as String);
      return progress;
    });
    when(() => logger.info(any())).thenAnswer((i) {
      infos.add(i.positionalArguments.single as String? ?? '');
    });
    when(() => logger.warn(any())).thenAnswer((i) {
      warnings.add(i.positionalArguments.single as String? ?? '');
    });
    when(() => logger.err(any())).thenAnswer((i) {
      errors.add(i.positionalArguments.single as String? ?? '');
    });
    when(() => progress.complete(any())).thenAnswer((i) {
      completed.add(i.positionalArguments.single as String? ?? '');
    });
    when(() => progress.fail(any())).thenAnswer((i) {
      failed.add(i.positionalArguments.single as String? ?? '');
    });
    when(() => progress.update(any())).thenAnswer((i) {
      updates.add(i.positionalArguments.single as String);
    });
  }

  final HostInfo host;
  final EngineFetchStatus fetch;
  final bool published;
  final int containerExit;
  final bool toolMissing;
  final EngineBuildResult build;
  late final Directory tmp;

  final logger = _MockLogger();
  final progress = _MockProgress();
  final started = <String>[];
  final completed = <String>[];
  final failed = <String>[];
  final updates = <String>[];
  final infos = <String>[];
  final warnings = <String>[];
  final errors = <String>[];

  /// The runtime argv of each container launch.
  final launches = <List<String>>[];
  final builds = <_Build>[];
  final engines = <_FakeEngine>[];

  /// Runs `emb engine -w <tmp> --commit abc123` plus [extra]; [withCommit]
  /// false leaves the commit to the (empty) workspace.
  Future<int?> run([List<String> extra = const [], bool withCommit = true]) {
    final command = EngineCommand(
      logger: logger,
      host: host,
      engineFactory: (Workspace ws) {
        final e = _FakeEngine(ws, fetch, published: published);
        engines.add(e);
        return e;
      },
      engineBuild:
          ({
            required commit,
            required arch,
            required mode,
            profile = ToolchainProfile.linuxGlibc,
            offline = false,
            strict = false,
          }) async {
            builds.add((
              commit: commit,
              arch: arch,
              mode: mode,
              profile: profile,
              offline: offline,
              strict: strict,
            ));
            return build;
          },
      containerLauncher: ContainerLauncher(
        run: (exe, args) async {
          if (toolMissing) throw ProcessException(exe, args, 'not found', 2);
          launches.add(args);
          return ProcessResult(0, containerExit, '', '');
        },
      ),
    );
    return (CommandRunner<int>('emb', 'test')..addCommand(command)).run([
      'engine',
      '-w',
      tmp.path,
      if (withCommit) ...['--commit', _commit],
      ...extra,
    ]);
  }

  /// What the inner emb is given: everything after `emb` in the one launch.
  List<String> get embArgs {
    final argv = launches.single;
    return argv.sublist(argv.indexOf('emb') + 1);
  }

  /// The runtime options of the one launch: everything before the image.
  List<String> get runtimeArgs {
    final argv = launches.single;
    return argv.sublist(0, argv.indexOf('emb') - 1);
  }

  /// The values of every [flag] among the runtime options.
  List<String> option(String flag) => [
    for (var i = 0; i < runtimeArgs.length - 1; i++)
      if (runtimeArgs[i] == flag) runtimeArgs[i + 1],
  ];
}

void main() {
  group('fetch', () {
    test('a fetched mode is success, with no build', () async {
      final h = _Harness(fetch: EngineFetchStatus.fetched);
      expect(await h.run(), ExitCode.success.code);
      expect(h.engines.single.fetches.single, (
        runtime: 'release',
        arch: 'arm64',
        commit: _commit,
        clean: false,
      ));
      expect(h.completed.single, contains('/store/release'));
      expect(h.launches, isEmpty);
      expect(h.builds, isEmpty);
      expect(h.engines.single.closed, isTrue);
    });

    test('an up-to-date mode is success', () async {
      final h = _Harness(fetch: EngineFetchStatus.upToDate);
      expect(await h.run(), ExitCode.success.code);
      expect(h.completed.single, contains('up to date'));
    });

    test('fetches each --mode, and passes --clean and --arch', () async {
      final h = _Harness(fetch: EngineFetchStatus.fetched);
      await h.run([
        '--mode',
        'release',
        '--mode',
        'profile',
        '--clean',
        '--arch',
        'x64',
      ]);
      expect(h.engines.single.fetches, [
        (runtime: 'release', arch: 'x86_64', commit: _commit, clean: true),
        (runtime: 'profile', arch: 'x86_64', commit: _commit, clean: true),
      ]);
    });

    test('a failed fetch is ExitCode.software', () async {
      final h = _Harness(fetch: EngineFetchStatus.failed);
      expect(await h.run(['--build-engine']), ExitCode.software.code);
      expect(h.failed.single, contains('fetch said no'));
      expect(h.launches, isEmpty);
      expect(h.builds, isEmpty);
      expect(h.engines.single.closed, isTrue);
    });

    test('no prebuilt and no --build-engine is unavailable', () async {
      final h = _Harness();
      expect(await h.run(), ExitCode.unavailable.code);
      expect(h.failed.single, contains('source build required'));
      expect(h.warnings.single, contains('--build-engine'));
      expect(h.launches, isEmpty);
      expect(h.builds, isEmpty);
    });

    test('no commit and none in the workspace is a usage error', () async {
      final h = _Harness();
      expect(await h.run(const [], false), ExitCode.usage.code);
      expect(h.errors.single, contains('engine.version'));
      expect(h.engines, isEmpty);
    });

    test('the commit defaults to the workspace engine.version', () async {
      final h = _Harness(fetch: EngineFetchStatus.fetched);
      File(p.join(h.tmp.path, 'flutter', 'bin', 'internal', 'engine.version'))
        ..createSync(recursive: true)
        ..writeAsStringSync('fromfile\n');
      expect(await h.run(const [], false), ExitCode.success.code);
      expect(h.engines.single.fetches.single.commit, 'fromfile');
    });
  });

  group('--check', () {
    test('published is success, and nothing is fetched', () async {
      final h = _Harness(published: true);
      expect(await h.run(['--check']), ExitCode.success.code);
      expect(h.engines.single.probes, ['release']);
      expect(h.engines.single.fetches, isEmpty);
    });

    test('not published is unavailable', () async {
      final h = _Harness();
      expect(await h.run(['--check']), ExitCode.unavailable.code);
      expect(h.infos, contains(contains('NOT published')));
      expect(h.engines.single.fetches, isEmpty);
    });
  });

  group('--build-engine in the container', () {
    test('a non-linux host builds in the container', () async {
      final h = _Harness();
      expect(await h.run(['--build-engine']), ExitCode.success.code);

      expect(h.builds, isEmpty);
      expect(h.embArgs, [
        'engine',
        '--build-engine',
        '--commit',
        _commit,
        '--arch',
        'arm64',
        '--mode',
        'release',
        '--libc',
        'glibc',
        '--exec-native',
      ]);
      expect(h.completed.single, contains('built in'));
    });

    test('a linux host that is not x86_64 builds in the container', () async {
      final h = _Harness(
        host: const HostInfo(
          os: HostOs.linux,
          machineArch: 'aarch64',
          archAliases: <String>{},
          hostType: 'linux',
          versionId: '24.04',
        ),
      );
      expect(await h.run(['--build-engine']), ExitCode.success.code);
      expect(h.builds, isEmpty);
      expect(h.launches, hasLength(1));
    });

    // The builder image sets FLUTTER_WORKSPACE itself; the host workspace
    // would select binaries that cannot run in it.
    test('-w is not forwarded to the inner emb', () async {
      final h = _Harness();
      await h.run(['--build-engine']);
      expect(h.embArgs, isNot(contains('-w')));
      expect(h.embArgs, isNot(contains('--workspace')));
      expect(h.embArgs, isNot(contains(h.tmp.path)));
    });

    test(
      'mounts the workspace and the cache, and works in the workspace',
      () async {
        final h = _Harness();
        await h.run(['--build-engine']);
        final cache = ensureCacheDir().path;
        expect(h.option('-v'), contains('${h.tmp.path}:${h.tmp.path}'));
        expect(h.option('-v'), contains('$cache:$cache'));
        expect(h.option('-w'), [h.tmp.path]);
      },
    );

    // Without it the inner emb resolves its own $HOME/.cache/emb and the
    // build's only output lands in the --rm container. Forwarded at a path
    // no mount exposes, it would land there just the same.
    test('forwards EMB_CACHE_DIR, at a path a mount exposes', () async {
      final h = _Harness();
      await h.run(['--build-engine']);
      final forwarded = [
        for (final e in h.option('-e'))
          if (e.startsWith('EMB_CACHE_DIR=')) e.substring(14),
      ];
      expect(forwarded, [ensureCacheDir().path]);
      expect(
        h.option('-v'),
        contains('${forwarded.single}:${forwarded.single}'),
      );
    });

    test('builds each unavailable mode in its own container run', () async {
      final h = _Harness();
      await h.run(['--build-engine', '--mode', 'release', '--mode', 'debug']);
      expect(h.launches, hasLength(2));
      expect(h.launches[0], containsAllInOrder(['--mode', 'release']));
      expect(h.launches[1], containsAllInOrder(['--mode', 'debug']));
    });

    test('forwards --libc and --sysroot-id', () async {
      final h = _Harness();
      await h.run(['--build-engine', '--libc', 'musl', '--sysroot-id', 'poky']);
      expect(h.embArgs, containsAllInOrder(['--libc', 'musl']));
      expect(h.embArgs, containsAllInOrder(['--sysroot-id', 'poky']));
    });

    test('forwards no --sysroot-id when none was passed', () async {
      final h = _Harness();
      await h.run(['--build-engine']);
      expect(h.embArgs, isNot(contains('--sysroot-id')));
    });

    group('offline', () {
      test('neither flag by default', () async {
        final h = _Harness();
        await h.run(['--build-engine']);
        expect(h.embArgs, isNot(contains('--offline')));
        expect(h.embArgs, isNot(contains('--offline-strict')));
      });

      test('--offline', () async {
        final h = _Harness();
        await h.run(['--build-engine', '--offline']);
        expect(h.embArgs, contains('--offline'));
        expect(h.embArgs, isNot(contains('--offline-strict')));
      });

      // Strict implies offline; forwarding both would be redundant, and
      // forwarding only --offline would drop the sandbox.
      test('--offline-strict alone', () async {
        final h = _Harness();
        await h.run(['--build-engine', '--offline-strict']);
        expect(h.embArgs, contains('--offline-strict'));
        expect(h.embArgs, isNot(contains('--offline')));
      });
    });

    test(
      'a failed container build is unavailable, with the exit code',
      () async {
        final h = _Harness(containerExit: 3);
        expect(await h.run(['--build-engine']), ExitCode.unavailable.code);
        expect(h.failed.single, contains('exit 3'));
        expect(h.warnings.single, contains('could not be source-built'));
      },
    );

    test('a missing container tool is unavailable, naming the tool', () async {
      final h = _Harness(toolMissing: true);
      expect(await h.run(['--build-engine']), ExitCode.unavailable.code);
      expect(h.failed.single, allOf(contains('docker'), contains('not found')));
      expect(h.builds, isEmpty);
    });

    group('reporting', () {
      tearDown(() => embVerbosity = Verbosity.normal);

      test('a spinner at normal verbosity', () async {
        final h = _Harness();
        await h.run(['--build-engine']);
        expect(h.started, ['Engine release']);
        expect(h.updates.single, contains('building in'));
      });

      // The container streams its build output to the terminal; a spinner
      // rewriting the current line would garble it.
      test('plain banners at -v, no spinner', () async {
        embVerbosity = Verbosity.verbose;
        final h = _Harness();
        await h.run(['--build-engine']);
        verifyNever(() => h.logger.progress(any()));
        expect(h.infos, contains('▶ Engine release'));
        expect(h.infos, contains(contains('built in')));
      });
    });
  });

  group('--build-engine natively', () {
    test('a linux x86_64 host builds without a container', () async {
      final h = _Harness(host: _linuxX64());
      expect(await h.run(['--build-engine']), ExitCode.success.code);
      expect(h.launches, isEmpty);
      final b = h.builds.single;
      expect(b.commit, _commit);
      expect(b.arch, 'x86_64');
      expect(b.mode, 'release');
      expect(b.profile.libc, Libc.glibc);
      expect(b.profile.sysrootId, isNull);
      expect(b.offline, isFalse);
      expect(b.strict, isFalse);
      expect(h.completed.single, contains('cached build'));
    });

    // The recursion guard: this is how the inner emb is invoked.
    test('--exec-native builds without a container on any host', () async {
      final h = _Harness();
      expect(
        await h.run(['--build-engine', '--exec-native']),
        ExitCode.success.code,
      );
      expect(h.launches, isEmpty);
      expect(h.builds, hasLength(1));
    });

    test('passes the toolchain profile and offline flags', () async {
      final h = _Harness(host: _linuxX64());
      await h.run([
        '--build-engine',
        '--libc',
        'musl',
        '--sysroot-id',
        'poky',
        '--offline-strict',
      ]);
      final b = h.builds.single;
      expect(b.profile.libc, Libc.musl);
      expect(b.profile.sysrootId, 'poky');
      expect(b.offline, isTrue);
      expect(b.strict, isTrue);
    });

    test('--offline is offline but not strict', () async {
      final h = _Harness(host: _linuxX64());
      await h.run(['--build-engine', '--offline']);
      expect(h.builds.single.offline, isTrue);
      expect(h.builds.single.strict, isFalse);
    });

    test('a failed build is unavailable, with its message', () async {
      final h = _Harness(
        host: _linuxX64(),
        build: const EngineBuildResult(
          EngineBuildStatus.failed,
          message: 'ninja exploded',
        ),
      );
      expect(await h.run(['--build-engine']), ExitCode.unavailable.code);
      expect(h.failed.single, contains('ninja exploded'));
    });

    test('an unsupported build is unavailable', () async {
      final h = _Harness(
        host: _linuxX64(),
        build: const EngineBuildResult(EngineBuildStatus.unsupported),
      );
      expect(await h.run(['--build-engine']), ExitCode.unavailable.code);
      expect(h.failed.single, contains('build failed'));
    });
  });

  test('a stray positional argument is rejected', () async {
    final h = _Harness();
    expect(() => h.run(['extra']), throwsA(isA<UsageException>()));
    expect(h.engines, isEmpty);
  });
}
