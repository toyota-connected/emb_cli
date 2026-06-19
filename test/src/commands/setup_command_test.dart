import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:emb_cli/src/commands/setup_command.dart';
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

/// Provisioner that records whether it was used and reports all satisfied.
class _FakeProvisioner implements HostProvisioner {
  bool availabilityChecked = false;
  @override
  String get name => 'fake';
  @override
  Future<bool> isAvailable() async {
    availabilityChecked = true;
    return true;
  }

  @override
  Future<List<String>?> availableUpdates() async => null;

  @override
  Future<Set<String>> missing(Set<String> names) async => {};
  @override
  Future<ProvisionPlan> simulate(Set<String> names) async =>
      ProvisionPlan(requested: names.toList(), toInstall: const []);
  @override
  Future<ProvisionResult> install(
    Set<String> names, {
    void Function(ProvisionProgress)? onProgress,
  }) async => ProvisionResult(installed: names.toList());
  @override
  Future<void> dispose() async {}
}

void main() {
  late Logger logger;
  late _MockProgress progress;

  setUp(() {
    logger = _MockLogger();
    progress = _MockProgress();
    when(() => logger.progress(any())).thenReturn(progress);
  });

  CommandRunner<int> runnerWith(_FakeProvisioner prov) {
    final runner = CommandRunner<int>('emb', 't')
      ..addCommand(
        SetupCommand(
          logger: logger,
          host: _host,
          provisionerFactory: (_) => prov,
        ),
      );
    return runner;
  }

  test('runs deps phase and skips sync/flutter/engine when asked', () async {
    final tmp = Directory.systemTemp.createTempSync('emb_setup_');
    addTearDown(() => tmp.deleteSync(recursive: true));
    // A config with deps so the deps phase has work.
    File(p.join(tmp.path, 'c.json')).writeAsStringSync('''
{"id":"c","supported_host_types":["fedora"],"deps":{"linux":{"fedora":["git"]}}}
''');

    final prov = _FakeProvisioner();
    final code = await runnerWith(prov).run([
      'setup',
      '--config',
      tmp.path,
      '-w',
      tmp.path,
      '--skip-sync',
      '--skip-flutter',
      '--skip-engine',
    ]);

    expect(code, ExitCode.success.code);
    expect(prov.availabilityChecked, isTrue); // deps phase ran
  });

  test('skip-deps avoids touching the provisioner', () async {
    final tmp = Directory.systemTemp.createTempSync('emb_setup_');
    addTearDown(() => tmp.deleteSync(recursive: true));

    final prov = _FakeProvisioner();
    final code = await runnerWith(prov).run([
      'setup',
      '--config',
      tmp.path,
      '-w',
      tmp.path,
      '--skip-deps',
      '--skip-sync',
      '--skip-flutter',
      '--skip-engine',
    ]);

    expect(code, ExitCode.success.code);
    expect(prov.availabilityChecked, isFalse);
  });
}
