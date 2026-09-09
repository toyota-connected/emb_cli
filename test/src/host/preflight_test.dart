import 'package:emb_cli/src/host/host_info.dart';
import 'package:emb_cli/src/host/preflight.dart';
import 'package:emb_cli/src/pkg/host_provisioner.dart';
import 'package:emb_cli/src/pkg/provision_models.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:test/test.dart';

const _host = HostInfo(
  os: HostOs.linux,
  machineArch: 'x86_64',
  archAliases: {'x86_64', 'x64', 'amd64'},
  hostType: 'ubuntu',
  versionId: '24.04',
);

/// Reports [absent] as not installed; everything else counts as present.
class _FakeProvisioner implements HostProvisioner {
  _FakeProvisioner({this.absent = const {}, this.available = true});

  final Set<String> absent;
  final bool available;
  int missingCalls = 0;

  @override
  String get name => 'fake';
  @override
  Future<bool> isAvailable() async => available;
  @override
  Future<List<String>?> availableUpdates() async => null;
  @override
  Future<Set<String>> missing(Set<String> names) async {
    missingCalls++;
    return names.intersection(absent);
  }

  @override
  Future<ProvisionPlan> simulate(Set<String> names) async =>
      ProvisionPlan(requested: names.toList(), toInstall: names.toList());
  @override
  Future<ProvisionResult> install(
    Set<String> names, {
    void Function(ProvisionProgress)? onProgress,
  }) async => ProvisionResult(installed: names.toList());
  @override
  Future<void> dispose() async {}
}

void main() {
  group('Preflight.missingTools', () {
    test('returns the subset the probe reports absent, in order', () async {
      final pf = Preflight(
        Logger(),
        probe: (t) async => t != 'xz' && t != 'rsync',
      );
      expect(await pf.missingTools(['tar', 'xz', 'rsync']), ['xz', 'rsync']);
    });

    test('is empty when every tool is present', () async {
      final pf = Preflight(Logger(), probe: (_) async => true);
      expect(await pf.missingTools(['tar', 'xz']), isEmpty);
    });

    test('an empty tool list never probes', () async {
      var probed = false;
      final pf = Preflight(
        Logger(),
        probe: (_) async {
          probed = true;
          return true;
        },
      );
      expect(await pf.missingTools(const []), isEmpty);
      expect(probed, isFalse);
    });
  });

  group('Preflight.missingPackages', () {
    // `which` can never see a -dev package: it ships headers and a .pc file
    // and no executable. This is why host_dev_packages needs its own probe.
    test('asks the backend, not PATH', () async {
      final fake = _FakeProvisioner(absent: {'libpugixml-dev'});
      final pf = Preflight(
        Logger(),
        probe: (_) async => fail('must not probe PATH for a package name'),
        provisionerFactory: (host, {interactive = true}) => fake,
      );
      expect(await pf.missingPackages(_host, ['libpugixml-dev']), [
        'libpugixml-dev',
      ]);
      expect(fake.missingCalls, 1);
    });

    test('empty when the backend reports everything installed', () async {
      final pf = Preflight(
        Logger(),
        provisionerFactory: (host, {interactive = true}) => _FakeProvisioner(),
      );
      expect(await pf.missingPackages(_host, ['libpugixml-dev']), isEmpty);
    });

    test('preserves the requested order', () async {
      final pf = Preflight(
        Logger(),
        provisionerFactory: (host, {interactive = true}) =>
            _FakeProvisioner(absent: {'c', 'a'}),
      );
      expect(await pf.missingPackages(_host, ['a', 'b', 'c']), ['a', 'c']);
    });

    test('null when the backend is unreachable', () async {
      final pf = Preflight(
        Logger(),
        provisionerFactory: (host, {interactive = true}) =>
            _FakeProvisioner(available: false),
      );
      expect(await pf.missingPackages(_host, ['libpugixml-dev']), isNull);
    });

    test('null when no backend is compiled in', () async {
      final pf = Preflight(
        Logger(),
        provisionerFactory: (host, {interactive = true}) =>
            throw UnsupportedError('no backend'),
      );
      expect(await pf.missingPackages(_host, ['libpugixml-dev']), isNull);
    });

    test('an empty package list never reaches the backend', () async {
      final pf = Preflight(
        Logger(),
        provisionerFactory: (host, {interactive = true}) =>
            throw StateError('must not build a provisioner'),
      );
      expect(await pf.missingPackages(_host, const []), isEmpty);
    });
  });
}
