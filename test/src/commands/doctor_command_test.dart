import 'package:args/command_runner.dart';
import 'package:emb_cli/src/commands/doctor_command.dart';
import 'package:emb_cli/src/host/host_info.dart';
import 'package:emb_cli/src/pkg/host_provisioner.dart';
import 'package:emb_cli/src/pkg/provision_models.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:test/test.dart';

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
}
