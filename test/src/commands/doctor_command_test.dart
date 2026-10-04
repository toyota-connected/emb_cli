import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:emb_cli/src/cache/store.dart';
import 'package:emb_cli/src/commands/doctor_command.dart';
import 'package:emb_cli/src/engine/engine_builder.dart';
import 'package:emb_cli/src/host/host_info.dart';
import 'package:emb_cli/src/host/preflight.dart';
import 'package:emb_cli/src/pkg/host_provisioner.dart';
import 'package:emb_cli/src/pkg/provision_models.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Captures `info` lines so a `--json` envelope can be parsed back.
class _CaptureLogger extends Logger {
  final StringBuffer buffer = StringBuffer();
  @override
  void info(String? message, {LogStyle? style}) => buffer.writeln(message);
}

const _host = HostInfo(
  os: HostOs.linux,
  machineArch: 'x86_64',
  archAliases: {'x86_64', 'x64', 'amd64'},
  hostType: 'fedora',
  versionId: '43',
);

class _FakeProvisioner implements HostProvisioner {
  _FakeProvisioner({
    this.available = true,
    this.updates,
    this.throwOnUpdates = false,
  });

  final bool available;
  final List<String>? updates;
  final bool throwOnUpdates;
  bool updatesChecked = false;

  @override
  String get name => 'fake';

  @override
  Future<bool> isAvailable() async => available;

  @override
  Future<List<String>?> availableUpdates() async {
    updatesChecked = true;
    if (throwOnUpdates) throw StateError('boom');
    return updates;
  }

  @override
  Future<Set<String>> missing(Set<String> names) async => {};

  @override
  Future<ProvisionPlan> simulate(Set<String> names) async =>
      ProvisionPlan.empty;

  @override
  Future<ProvisionResult> install(
    Set<String> names, {
    void Function(ProvisionProgress progress)? onProgress,
  }) async => ProvisionResult(installed: names.toList());

  @override
  Future<void> dispose() async {}
}

Future<int?> _run(_FakeProvisioner p) {
  final runner = CommandRunner<int>('emb', 'test')
    ..addCommand(
      DoctorCommand(
        logger: Logger(),
        host: _host,
        provisionerFactory: (_) => p,
      ),
    );
  return runner.run(['doctor']);
}

Future<(int?, Map<String, dynamic>)> _runJson(_FakeProvisioner p) async {
  final logger = _CaptureLogger();
  final runner = CommandRunner<int>('emb', 'test')
    ..addCommand(
      DoctorCommand(logger: logger, host: _host, provisionerFactory: (_) => p),
    );
  final code = await runner.run(['doctor', '--json']);
  return (code, jsonDecode(logger.buffer.toString()) as Map<String, dynamic>);
}

void main() {
  test('checks for updates when the backend is available', () async {
    final p = _FakeProvisioner(updates: ['a', 'b', 'c']);
    expect(await _run(p), ExitCode.success.code);
    expect(p.updatesChecked, isTrue);
  });

  test('an empty update list (up to date) succeeds', () async {
    final p = _FakeProvisioner(updates: const []);
    expect(await _run(p), ExitCode.success.code);
    expect(p.updatesChecked, isTrue);
  });

  test("a backend that can't report updates (null) succeeds", () async {
    final p = _FakeProvisioner();
    expect(await _run(p), ExitCode.success.code);
    expect(p.updatesChecked, isTrue);
  });

  test('an update-check error never fails doctor', () async {
    final p = _FakeProvisioner(throwOnUpdates: true);
    expect(await _run(p), ExitCode.success.code);
    expect(p.updatesChecked, isTrue);
  });

  test(
    'an unavailable backend exits unavailable and skips the update check',
    () {
      final p = _FakeProvisioner(available: false);
      return _run(p).then((code) {
        expect(code, ExitCode.unavailable.code);
        expect(p.updatesChecked, isFalse);
      });
    },
  );

  test('--json emits the {schema, command, ok, data} envelope', () async {
    final (code, json) = await _runJson(_FakeProvisioner(updates: ['a', 'b']));
    expect(code, ExitCode.success.code);
    expect(json['schema'], 1);
    expect(json['command'], 'doctor');
    expect(json['ok'], true);
    final data = json['data'] as Map<String, dynamic>;
    expect((data['host'] as Map)['os'], 'linux');
    final backend = data['backend'] as Map<String, dynamic>;
    expect(backend['name'], 'fake');
    expect(backend['available'], true);
    expect((backend['updates'] as Map)['count'], 2);
    // boards shape: always has source, installed, count, names; versions is a
    // list of {version, source, skewed} when stamps exist.
    final boards = data['boards'] as Map<String, dynamic>;
    expect(boards, containsPair('source', isA<String>()));
    expect(boards, containsPair('installed', isA<String>()));
    expect(boards, containsPair('count', isA<int>()));
    expect(boards, containsPair('names', isA<List<dynamic>>()));
    // `versions` is absent only when no source carries a stamp; when present
    // every entry must carry the full shape. The stamped case is asserted
    // outright below, so this loop is no longer the only coverage.
    for (final v in (boards['versions'] as List?) ?? const []) {
      final entry = v as Map<String, dynamic>;
      expect(entry, containsPair('version', isA<String>()));
      expect(entry, containsPair('source', isA<String>()));
      expect(entry, containsPair('skewed', isA<bool>()));
    }
  });

  test('--json reports a version stamp per board source', () async {
    // The shape assertion used to sit behind `if (boards.containsKey(...))`, so
    // it passed on any machine with no stamped install — i.e. vacuously in CI.
    // Point doctor at a fixture that has one and assert the stamp is reported.
    final tmp = Directory.systemTemp.createTempSync('emb_doctor_boards_');
    addTearDown(() => tmp.deleteSync(recursive: true));
    // The installed data dir, not EMB_BOARDS_DIR: _boardStamps enumerates the
    // sources declared in boards.yaml (default: emb-public) under
    // <data>/emb/boards/<name>. A stamp in an EMB_BOARDS_DIR checkout is
    // reported by neither path — see the known gap in the PR description.
    final source = Directory(
      p.join(tmp.path, 'data', 'emb', 'boards', 'emb-public'),
    )..createSync(recursive: true);
    File(p.join(source.path, 'b.emb.yaml')).writeAsStringSync('''
id: b
type: board
cross:
  provider: arm-gnu
  targets:
    rpi5-trixie: {}
''');
    File(p.join(source.path, '.emb-boards-version')).writeAsStringSync('9.9.9');

    final logger = _CaptureLogger();
    final runner = CommandRunner<int>('emb', 'test')
      ..addCommand(
        DoctorCommand(
          logger: logger,
          host: _host,
          provisionerFactory: (_) => _FakeProvisioner(),
          environment: {
            'HOME': tmp.path,
            'XDG_DATA_HOME': p.join(tmp.path, 'data'),
            'XDG_CONFIG_HOME': p.join(tmp.path, 'config'),
          },
        ),
      );
    await runner.run(['doctor', '--json']);
    final data =
        (jsonDecode(logger.buffer.toString()) as Map<String, dynamic>)['data']
            as Map<String, dynamic>;
    final boards = data['boards'] as Map<String, dynamic>;
    expect(boards['names'], contains('emb-public/rpi5-trixie'));
    final versions = boards['versions'] as List;
    expect(versions, hasLength(1));
    final entry = versions.single as Map<String, dynamic>;
    expect(entry['version'], '9.9.9');
    expect(entry['source'], 'emb-public');
    // 9.9.9 is not this emb, so the skew must be reported, not hidden.
    expect(entry['skewed'], isTrue);
  });

  test('--json reports ok:false when the backend is unavailable', () async {
    final (code, json) = await _runJson(_FakeProvisioner(available: false));
    expect(code, ExitCode.unavailable.code);
    expect(json['ok'], false);
    expect(((json['data'] as Map)['backend'] as Map)['available'], false);
  });

  group('--target', () {
    late Directory tmp;
    late String manifest;
    setUp(() {
      tmp = Directory.systemTemp.createTempSync('emb_doctor_');
      manifest = p.join(tmp.path, 'pi.emb.yaml');
      File(manifest).writeAsStringSync('''
id: doctor-fixture
cross:
  provider: arm-gnu
  triple: aarch64-none-linux-gnu
  image_url: https://example/os.img.xz
  targets:
    pi5: {cpu_flags: [-mcpu=cortex-a76]}
''');
    });
    tearDown(() => tmp.deleteSync(recursive: true));

    // A Preflight whose `which` probe reports [missing] as absent.
    Preflight fakePreflight(Logger logger, Set<String> missing) =>
        Preflight(logger, probe: (t) async => !missing.contains(t));

    Future<int?> runTarget(
      String target, {
      Logger? logger,
      Set<String> missing = const {},
    }) {
      final log = logger ?? Logger();
      final runner = CommandRunner<int>('emb', 'test')
        ..addCommand(
          DoctorCommand(
            logger: log,
            host: _host,
            provisionerFactory: (_) => _FakeProvisioner(),
            preflight: fakePreflight(log, missing),
          ),
        );
      return runner.run(['doctor', '--target', target, manifest]);
    }

    test('a target whose preflight tools are all present succeeds', () async {
      expect(await runTarget('pi5'), ExitCode.success.code);
    });

    test('a missing preflight tool exits unavailable', () async {
      expect(
        await runTarget('pi5', missing: {'rsync'}),
        ExitCode.unavailable.code,
      );
    });

    test('the native target has no preflight tools (always ok)', () async {
      expect(await runTarget('local'), ExitCode.success.code);
    });

    test('an unknown target is a usage error', () async {
      expect(await runTarget('nope'), ExitCode.usage.code);
    });

    test('--json carries target.preflight.{ok, missing}', () async {
      final logger = _CaptureLogger();
      final runner = CommandRunner<int>('emb', 'test')
        ..addCommand(
          DoctorCommand(
            logger: logger,
            host: _host,
            provisionerFactory: (_) => _FakeProvisioner(),
            preflight: fakePreflight(logger, {'rsync'}),
          ),
        );
      final code = await runner.run([
        'doctor',
        '--json',
        '--target',
        'pi5',
        manifest,
      ]);
      final json = jsonDecode(logger.buffer.toString()) as Map<String, dynamic>;
      expect(code, ExitCode.unavailable.code);
      expect(json['ok'], false);
      final target = (json['data'] as Map)['target'] as Map<String, dynamic>;
      expect(target['name'], 'pi5');
      expect(target['provider'], 'arm-gnu');
      final preflight = target['preflight'] as Map<String, dynamic>;
      expect(preflight['ok'], false);
      expect(preflight['missing'], ['rsync']);
    });
  });

  group('--offline-probe', () {
    late Directory tmp;
    late String manifest;
    setUp(() {
      tmp = Directory.systemTemp.createTempSync('emb_probe_');
      manifest = p.join(tmp.path, 'app.emb.yaml');
      File(manifest).writeAsStringSync('''
id: probe-fixture
cross:
  provider: arm-gnu
  image_url: https://example/os.img.xz
''');
    });
    tearDown(() => tmp.deleteSync(recursive: true));

    Future<int?> probe(List<String> extra, {Logger? logger}) {
      final log = logger ?? Logger();
      final runner = CommandRunner<int>('emb', 'test')
        ..addCommand(DoctorCommand(logger: log, host: _host));
      return runner.run(['doctor', '--offline-probe', ...extra, manifest]);
    }

    test('a native target has no closure to fetch and passes', () async {
      // Native: no toolchain/sysroot resolve, no cargo modules; the only check
      // is isolation, which is not required without --strict.
      expect(await probe(['--target', 'local']), ExitCode.success.code);
    });

    test('an unknown target exits usage', () async {
      expect(await probe(['--target', 'nope']), ExitCode.usage.code);
    });

    test('the json envelope carries the probe verdict', () async {
      final logger = _CaptureLogger();
      final code = await probe(['--target', 'local', '--json'], logger: logger);
      expect(code, ExitCode.success.code);
      final json = jsonDecode(logger.buffer.toString()) as Map<String, dynamic>;
      expect(json['ok'], true);
      final probeData =
          (json['data'] as Map)['offline_probe'] as Map<String, dynamic>;
      expect(probeData['target'], 'local');
      expect(probeData['ok'], true);
      expect(probeData['checks'], isNotEmpty);
    });
  });

  group('--offline-probe --engine-commit', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('emb_engine_probe_'));
    tearDown(() => tmp.deleteSync(recursive: true));

    Future<int?> probe(List<String> extra, {Logger? logger}) {
      final log = logger ?? Logger();
      final runner = CommandRunner<int>('emb', 'test')
        ..addCommand(
          DoctorCommand(
            logger: log,
            host: _host,
            environment: {'EMB_CACHE_DIR': tmp.path},
          ),
        );
      return runner.run([
        'doctor',
        '--offline-probe',
        '--engine-commit',
        'abc',
        ...extra,
      ]);
    }

    void seedClosure() {
      Store(
        Directory(tmp.path),
      ).rootOf(EngineBuilder.srcKind, 'abc').createSync(recursive: true);
    }

    test('missing closure is unavailable', () async {
      expect(await probe(const []), ExitCode.unavailable.code);
    });

    test('a materialized closure passes (non-strict)', () async {
      seedClosure();
      expect(await probe(const []), ExitCode.success.code);
    });

    test('the json envelope carries the engine verdict', () async {
      seedClosure();
      final logger = _CaptureLogger();
      final code = await probe(const ['--json'], logger: logger);
      expect(code, ExitCode.success.code);
      final json = jsonDecode(logger.buffer.toString()) as Map<String, dynamic>;
      expect(json['ok'], true);
      final probeData =
          (json['data'] as Map)['offline_probe'] as Map<String, dynamic>;
      expect(probeData['target'], 'engine:abc');
      expect(probeData['ok'], true);
    });
  });
}
