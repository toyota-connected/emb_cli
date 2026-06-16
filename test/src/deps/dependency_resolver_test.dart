import 'package:emb_cli/src/deps/dependency_resolver.dart';
import 'package:emb_cli/src/host/host_info.dart';
import 'package:emb_cli/src/manifest/emb_manifest.dart';
import 'package:emb_cli/src/pkg/host_provisioner.dart';
import 'package:emb_cli/src/pkg/provision_models.dart';
import 'package:test/test.dart';

/// A provisioner whose "installed" set is fixed, for filtering tests.
class _FakeProvisioner implements HostProvisioner {
  _FakeProvisioner(this.installed);
  final Set<String> installed;

  @override
  String get name => 'fake';

  @override
  Future<bool> isAvailable() async => true;

  @override
  Future<Set<String>> missing(Set<String> names) async =>
      names.difference(installed);

  @override
  Future<ProvisionPlan> simulate(Set<String> names) async => ProvisionPlan(
    requested: names.toList(),
    toInstall: names.difference(installed).toList(),
  );

  @override
  Future<ProvisionResult> install(
    Set<String> names, {
    void Function(ProvisionProgress progress)? onProgress,
  }) async => ProvisionResult(installed: names.toList());

  @override
  Future<void> dispose() async {}
}

HostInfo _fedora() => const HostInfo(
  os: HostOs.linux,
  machineArch: 'x86_64',
  archAliases: {'x86_64', 'x64', 'amd64'},
  hostType: 'fedora',
  versionId: '43',
);

EmbManifest _manifest(
  String id,
  Map<String, dynamic> deps, {
  List<String> archs = const [],
  List<String> hostTypes = const [],
}) => EmbManifest.fromMap({
  'id': id,
  'type': 'dependency',
  if (archs.isNotEmpty) 'supported_archs': archs,
  if (hostTypes.isNotEmpty) 'supported_host_types': hostTypes,
  'deps': deps,
});

void main() {
  final resolver = DependencyResolver(_fedora());

  group('coalesce', () {
    test('unions and de-duplicates across manifests', () {
      final result = resolver.coalesce([
        _manifest('a', {
          'linux': {
            'fedora': ['git', 'cmake'],
          },
        }),
        _manifest('b', {
          'linux': {
            'fedora': ['cmake', 'ninja-build'],
          },
        }),
      ]);
      expect(result.packages, ['cmake', 'git', 'ninja-build']); // sorted+unique
      expect(result.byComponent.keys, containsAll(['a', 'b']));
    });

    test('skips components whose arch does not apply', () {
      final result = resolver.coalesce([
        _manifest(
          'arm-only',
          {
            'linux': {
              'fedora': ['should-not-appear'],
            },
          },
          archs: ['aarch64'],
        ),
      ]);
      expect(result.packages, isEmpty);
      expect(result.skipped, ['arm-only']);
    });

    test('skips components whose host type does not apply', () {
      final result = resolver.coalesce([
        _manifest(
          'ubuntu-only',
          {
            'linux': {
              'ubuntu': ['libfreetype-dev'],
            },
          },
          hostTypes: ['ubuntu'],
        ),
      ]);
      expect(result.skipped, ['ubuntu-only']);
    });
  });

  group('filter', () {
    test('subtracts already-installed packages', () async {
      final coalesced = resolver.coalesce([
        _manifest('a', {
          'linux': {
            'fedora': ['git', 'cmake', 'ninja-build'],
          },
        }),
      ]);
      final provisioner = _FakeProvisioner({'git'});
      final filtered = await resolver.filter(coalesced, provisioner);
      expect(filtered.required, ['cmake', 'git', 'ninja-build']);
      expect(filtered.missing, ['cmake', 'ninja-build']);
      expect(filtered.isSatisfied, isFalse);
    });

    test('isSatisfied when everything is installed', () async {
      final coalesced = resolver.coalesce([
        _manifest('a', {
          'linux': {
            'fedora': ['git'],
          },
        }),
      ]);
      final filtered = await resolver.filter(
        coalesced,
        _FakeProvisioner({'git'}),
      );
      expect(filtered.isSatisfied, isTrue);
    });
  });

  group('contentHash', () {
    List<EmbManifest> manifests() => [
      _manifest('a', {
        'linux': {
          'fedora': ['git', 'cmake'],
        },
      }),
      _manifest('b', {
        'linux': {
          'fedora': ['cmake', 'ninja-build'],
        },
      }),
    ];

    test('is stable regardless of manifest order', () {
      final h1 = resolver.coalesce(manifests()).contentHash;
      final h2 = resolver.coalesce(manifests().reversed.toList()).contentHash;
      expect(h1, h2);
    });

    test('changes when the package set changes', () {
      final base = resolver.coalesce(manifests()).contentHash;
      final more = resolver.coalesce([
        ...manifests(),
        _manifest('c', {
          'linux': {
            'fedora': ['extra-pkg'],
          },
        }),
      ]).contentHash;
      expect(base, isNot(more));
    });

    test('changes when the host changes', () {
      final fedoraHash = resolver.coalesce(manifests()).contentHash;
      const ubuntu = DependencyResolver(
        HostInfo(
          os: HostOs.linux,
          machineArch: 'x86_64',
          archAliases: {'x86_64', 'x64', 'amd64'},
          hostType: 'ubuntu',
          versionId: '22.04',
        ),
      );
      // Same package set, different host identity → different cache key.
      final ubuntuHash = ubuntu.coalesce([
        _manifest('a', {
          'linux': {
            'fedora': ['git', 'cmake'],
            'ubuntu': ['git', 'cmake'],
          },
        }),
        _manifest('b', {
          'linux': {
            'fedora': ['cmake', 'ninja-build'],
            'ubuntu': ['cmake', 'ninja-build'],
          },
        }),
      ]).contentHash;
      expect(fedoraHash, isNot(ubuntuHash));
    });
  });
}
