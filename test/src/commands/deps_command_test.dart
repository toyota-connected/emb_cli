import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:emb_cli/src/commands/deps_command.dart';
import 'package:emb_cli/src/host/host_info.dart';
import 'package:emb_cli/src/pkg/host_provisioner.dart';
import 'package:emb_cli/src/pkg/provision_models.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:mocktail/mocktail.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

class _MockLogger extends Mock implements Logger {}

class _MockProgress extends Mock implements Progress {}

const _host = HostInfo(
  os: HostOs.linux,
  machineArch: 'x86_64',
  archAliases: {'x86_64', 'x64', 'amd64'},
  hostType: 'fedora',
  versionId: '43',
);

/// Reports one missing package and returns a canned install outcome.
class _FakeProvisioner implements HostProvisioner {
  _FakeProvisioner({this.result});

  final ProvisionResult? result;
  bool interactiveSeen = true;

  @override
  String get name => 'fake';
  @override
  Future<bool> isAvailable() async => true;
  @override
  Future<List<String>?> availableUpdates() async => null;
  @override
  Future<Set<String>> missing(Set<String> names) async => names;
  @override
  Future<ProvisionPlan> simulate(Set<String> names) async =>
      ProvisionPlan(requested: names.toList(), toInstall: names.toList());
  @override
  Future<ProvisionResult> install(
    Set<String> names, {
    void Function(ProvisionProgress)? onProgress,
  }) async => result ?? ProvisionResult(installed: names.toList());
  @override
  Future<void> dispose() async {}
}

/// A manifest declaring one host package, so `deps` has something to do.
Directory _configDir() {
  final dir = Directory.systemTemp.createTempSync('emb_deps_test');
  File(p.join(dir.path, 'thing.json')).writeAsStringSync('''
{
  "id": "thing",
  "load": true,
  "deps": { "linux": { "fedora": ["cowsay"] } }
}
''');
  return dir;
}

void main() {
  late Logger logger;
  late _MockProgress progress;
  late Directory configs;
  final infoLines = <String>[];

  setUp(() {
    logger = _MockLogger();
    progress = _MockProgress();
    infoLines.clear();
    when(() => logger.progress(any())).thenReturn(progress);
    when(() => logger.info(any())).thenAnswer((i) {
      infoLines.add('${i.positionalArguments.first}');
    });
    configs = _configDir();
  });

  tearDown(() => configs.deleteSync(recursive: true));

  Future<int> run(
    List<String> args, {
    _FakeProvisioner? prov,
    Map<String, String> env = const {},
  }) async {
    final runner = CommandRunner<int>('emb', 'test')
      ..addCommand(
        DepsCommand(
          logger: logger,
          host: _host,
          environment: env,
          provisionerFactory: (_, {bool interactive = true}) {
            final p = prov ?? _FakeProvisioner();
            return p..interactiveSeen = interactive;
          },
        ),
      );
    return await runner.run(['deps', '--config', configs.path, ...args]) ?? 0;
  }

  group('interactivity threading', () {
    test('defaults to interactive', () async {
      final prov = _FakeProvisioner();
      await run(['--yes'], prov: prov);
      expect(prov.interactiveSeen, isTrue);
    });

    test('--no-interactive reaches the provisioner', () async {
      final prov = _FakeProvisioner();
      await run(['--no-interactive'], prov: prov);
      expect(prov.interactiveSeen, isFalse);
    });

    test('EMB_NON_INTERACTIVE reaches the provisioner', () async {
      final prov = _FakeProvisioner();
      await run([], prov: prov, env: const {'EMB_NON_INTERACTIVE': '1'});
      expect(prov.interactiveSeen, isFalse);
    });

    test('CI alone does not flip it', () async {
      final prov = _FakeProvisioner();
      await run(['--yes'], prov: prov, env: const {'CI': 'true'});
      expect(prov.interactiveSeen, isTrue);
    });
  });

  group('--yes decoupling', () {
    test('--no-interactive implies --yes: no confirmation is asked', () async {
      await run(['--no-interactive']);
      verifyNever(
        () => logger.confirm(any(), defaultValue: any(named: 'defaultValue')),
      );
    });

    test('interactive without --yes still confirms', () async {
      when(
        () => logger.confirm(any(), defaultValue: any(named: 'defaultValue')),
      ).thenReturn(false);
      await run([]);
      verify(
        () => logger.confirm(any(), defaultValue: any(named: 'defaultValue')),
      ).called(1);
    });
  });

  group('authorization failure', () {
    test('notAuthorized prints remediation naming the polkit rule', () async {
      final prov = _FakeProvisioner(
        result: const ProvisionResult(
          installed: [],
          failed: ['cowsay'],
          message: 'Failed to obtain authentication.',
          kind: ProvisionFailure.notAuthorized,
        ),
      );
      final code = await run(['--yes'], prov: prov);
      expect(code, isNot(0));
      final out = infoLines.join('\n');
      expect(out, contains('polkit.addRule'));
      expect(out, contains('49-emb-packagekit.rules'));
    });

    test('a non-auth failure prints no authorization advice', () async {
      final prov = _FakeProvisioner(
        result: const ProvisionResult(
          installed: [],
          failed: ['cowsay'],
          message: 'disk full',
          kind: ProvisionFailure.other,
        ),
      );
      await run(['--yes'], prov: prov);
      expect(infoLines.join('\n'), isNot(contains('polkit.addRule')));
    });
  });
}
