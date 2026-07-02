import 'dart:convert';

import 'package:args/command_runner.dart';
import 'package:emb_cli/src/commands/doctor_command.dart';
import 'package:emb_cli/src/host/host_info.dart';
import 'package:emb_cli/src/pkg/host_provisioner.dart';
import 'package:emb_cli/src/pkg/provision_models.dart';
import 'package:mason_logger/mason_logger.dart';
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
  });

  test('--json reports ok:false when the backend is unavailable', () async {
    final (code, json) = await _runJson(_FakeProvisioner(available: false));
    expect(code, ExitCode.unavailable.code);
    expect(json['ok'], false);
    expect(((json['data'] as Map)['backend'] as Map)['available'], false);
  });
}
