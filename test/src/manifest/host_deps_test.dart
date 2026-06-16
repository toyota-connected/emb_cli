import 'package:emb_cli/src/host/host_info.dart';
import 'package:emb_cli/src/manifest/host_deps.dart';
import 'package:test/test.dart';

HostInfo _host({
  HostOs os = HostOs.linux,
  String hostType = 'fedora',
  String versionId = '43',
  String arch = 'x86_64',
}) =>
    HostInfo(
      os: os,
      machineArch: arch,
      archAliases: arch == 'x86_64' ? {'x86_64', 'x64', 'amd64'} : {arch},
      hostType: hostType,
      versionId: versionId,
    );

void main() {
  group('extractPackageNames', () {
    test('extracts from dnf install', () {
      expect(
        extractPackageNames('sudo dnf -y install libffi-devel libxml2-devel'),
        ['libffi-devel', 'libxml2-devel'],
      );
    });

    test('extracts from apt-get with mixed flags', () {
      expect(
        extractPackageNames(
            'sudo apt-get install -yq graphviz libffi-dev ninja-build'),
        ['graphviz', 'libffi-dev', 'ninja-build'],
      );
    });

    test('extracts from apt with long flags', () {
      expect(
        extractPackageNames(
            'sudo apt install --no-install-recommends -y git curl'),
        ['git', 'curl'],
      );
    });

    test('ignores non-package-manager commands', () {
      expect(extractPackageNames('pip3 install meson'), isEmpty);
      expect(extractPackageNames('meson setup build'), isEmpty);
      expect(extractPackageNames('git reset --hard'), isEmpty);
      expect(extractPackageNames(r'${AUTONINJA} -C build install'), isEmpty);
    });

    test('handles pacman -S', () {
      expect(
        extractPackageNames('sudo pacman -S wayland weston'),
        ['wayland', 'weston'],
      );
    });
  });

  group('HostDeps.fromStructured', () {
    final deps = HostDeps.fromStructured({
      'linux': {
        'fedora': ['pkg-config', 'freetype-devel'],
        'ubuntu': ['pkg-config', 'libfreetype-dev'],
      },
      'macos': ['pkg-config', 'freetype'],
      'windows': ['Kitware.CMake'],
    });

    test('resolves the matching distro list', () {
      expect(deps.resolve(_host()), ['pkg-config', 'freetype-devel']);
    });

    test('resolves macos flat list', () {
      expect(
        deps.resolve(_host(os: HostOs.macos, hostType: 'darwin')),
        ['pkg-config', 'freetype'],
      );
    });

    test('resolves windows list', () {
      expect(
        deps.resolve(_host(os: HostOs.windows, hostType: 'windows')),
        ['Kitware.CMake'],
      );
    });
  });

  group('HostDeps.fromLegacyPreRequisites', () {
    final deps = HostDeps.fromLegacyPreRequisites({
      'x86_64': {
        'fedora': {
          'cmds': ['sudo dnf -y install freetype-devel git'],
          '40': {
            'cmds': ['sudo dnf -y install ffmpeg-free-devel'],
          },
          '41': {
            'cmds': ['sudo dnf -y install ffmpeg-devel'],
          },
        },
        'ubuntu': {
          '22.0.4': {
            'cmds': ['sudo apt-get install -yq libfreetype-dev'],
          },
        },
      },
    });

    test('includes distro-level packages for any version', () {
      final pkgs = deps.resolve(_host());
      expect(pkgs, containsAll(['freetype-devel', 'git']));
      // No version-specific match for 43.
      expect(pkgs, isNot(contains('ffmpeg-devel')));
    });

    test('adds version-specific packages when version matches', () {
      final pkgs = deps.resolve(_host(versionId: '41'));
      expect(pkgs, containsAll(['freetype-devel', 'git', 'ffmpeg-devel']));
    });

    test('does not match a different arch', () {
      final pkgs = deps.resolve(_host(arch: 'aarch64'));
      expect(pkgs, isEmpty);
    });

    test('matches ubuntu version-specific only on ubuntu', () {
      final fedora = deps.resolve(_host(versionId: '22.0.4'));
      expect(fedora, isNot(contains('libfreetype-dev')));
      final ubuntu = deps.resolve(
        _host(hostType: 'ubuntu', versionId: '22.0.4'),
      );
      expect(ubuntu, contains('libfreetype-dev'));
    });
  });
}
