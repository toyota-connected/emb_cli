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

/// Reports [absent] as not installed. Names also in [unknown] come back from
/// simulate() as unresolved — the backend does not recognize them at all.
class _FakeProvisioner implements HostProvisioner {
  _FakeProvisioner({
    this.absent = const {},
    this.unknown = const {},
    this.available = true,
  });

  final Set<String> absent;
  final Set<String> unknown;
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
  Future<ProvisionPlan> simulate(Set<String> names) async => ProvisionPlan(
    requested: names.toList(),
    toInstall: names.difference(unknown).toList(),
    unresolved: names.intersection(unknown).toList(),
  );
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
    Preflight pf(_FakeProvisioner fake, {ToolProbe? probe}) => Preflight(
      Logger(),
      probe: probe ?? (_) async => true,
      provisionerFactory: (host, {interactive = true}) => fake,
    );

    // `which` can never see a -dev package: it ships headers and a .pc file
    // and no executable. This is why host_dev_packages needs its own probe.
    test('asks the backend, not PATH', () async {
      final fake = _FakeProvisioner(absent: {'libpugixml-dev'});
      final r = await pf(
        fake,
        probe: (_) async => fail('must not probe PATH for a package name'),
      ).missingPackages(_host, ['libpugixml-dev']);
      expect(r!.missing, ['libpugixml-dev']);
      expect(r.unresolved, isEmpty);
      expect(fake.missingCalls, 1);
    });

    test('empty when the backend reports everything installed', () async {
      final r = await pf(
        _FakeProvisioner(),
      ).missingPackages(_host, ['libpugixml-dev']);
      expect(r!.missing, isEmpty);
      expect(r.unresolved, isEmpty);
    });

    test(
      'a name the backend cannot resolve is unresolved, not missing',
      () async {
        // The Fedora case: libpugixml-dev is spelled pugixml-devel
        // there, so the backend reports it uninstalled AND unplaceable.
        // That must warn, not fail the build.
        final r = await pf(
          _FakeProvisioner(
            absent: {'libpugixml-dev'},
            unknown: {'libpugixml-dev'},
          ),
        ).missingPackages(_host, ['libpugixml-dev']);
        expect(r!.unresolved, ['libpugixml-dev']);
        expect(r.missing, isEmpty);
      },
    );

    test('splits a mixed set into missing and unresolved', () async {
      final r = await pf(
        _FakeProvisioner(absent: {'a', 'c'}, unknown: {'c'}),
      ).missingPackages(_host, ['a', 'b', 'c']);
      expect(r!.missing, ['a']);
      expect(r.unresolved, ['c']);
    });

    test('preserves the requested order', () async {
      final r = await pf(
        _FakeProvisioner(absent: {'c', 'a'}),
      ).missingPackages(_host, ['a', 'b', 'c']);
      expect(r!.missing, ['a', 'c']);
    });

    test('null when the backend is unreachable', () async {
      final r = await pf(
        _FakeProvisioner(available: false),
      ).missingPackages(_host, ['libpugixml-dev']);
      expect(r, isNull);
    });

    test('null when no backend is compiled in', () async {
      final p = Preflight(
        Logger(),
        provisionerFactory: (host, {interactive = true}) =>
            throw UnsupportedError('no backend'),
      );
      expect(await p.missingPackages(_host, ['libpugixml-dev']), isNull);
    });

    test('an empty package list never reaches the backend', () async {
      final p = Preflight(
        Logger(),
        provisionerFactory: (host, {interactive = true}) =>
            throw StateError('must not build a provisioner'),
      );
      final r = await p.missingPackages(_host, const []);
      expect(r!.missing, isEmpty);
      expect(r.unresolved, isEmpty);
    });
  });
}
