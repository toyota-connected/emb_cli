import 'package:emb_cli/src/host/host_info.dart';
import 'package:emb_cli/src/host/install_hint.dart';
import 'package:test/test.dart';

HostInfo _linux(String id) => HostInfo(
  os: HostOs.linux,
  machineArch: 'x86_64',
  archAliases: const {'x86_64'},
  hostType: id,
  versionId: '1',
);

const _macos = HostInfo(
  os: HostOs.macos,
  machineArch: 'arm64',
  archAliases: {'arm64'},
  hostType: 'darwin',
  versionId: '14',
);

const _windows = HostInfo(
  os: HostOs.windows,
  machineArch: 'x86_64',
  archAliases: {'x86_64'},
  hostType: 'windows',
  versionId: '11',
);

void main() {
  group('staticInstallHint', () {
    test('debian family → apt-get, xz mapped to xz-utils', () {
      expect(
        staticInstallHint(_linux('ubuntu'), ['tar', 'xz', 'rsync']),
        'sudo apt-get install -y tar xz-utils rsync',
      );
      expect(
        staticInstallHint(_linux('debian'), ['tar']),
        'sudo apt-get install -y tar',
      );
    });

    test('fedora family → dnf, pkg-config mapped to pkgconf-pkg-config', () {
      expect(
        staticInstallHint(_linux('fedora'), ['pkg-config']),
        'sudo dnf install -y pkgconf-pkg-config',
      );
      // xz keeps its name on dnf.
      expect(
        staticInstallHint(_linux('rocky'), ['xz']),
        'sudo dnf install -y xz',
      );
    });

    test('arch → pacman, pkg-config mapped to pkgconf', () {
      expect(
        staticInstallHint(_linux('arch'), ['pkg-config', 'rsync']),
        'sudo pacman -S --needed pkgconf rsync',
      );
    });

    test('openSUSE → zypper, alpine → apk', () {
      expect(
        staticInstallHint(_linux('opensuse-tumbleweed'), ['tar']),
        'sudo zypper install -y tar',
      );
      expect(staticInstallHint(_linux('alpine'), ['xz']), 'sudo apk add xz');
    });

    test('macOS → brew', () {
      expect(
        staticInstallHint(_macos, ['pkg-config']),
        'brew install pkg-config',
      );
    });

    test('Windows → winget', () {
      expect(
        staticInstallHint(_windows, ['tar', 'rsync']),
        'winget install tar rsync',
      );
    });

    test('deduplicates collapsed package names', () {
      // Two distinct tools, but only the package set is emitted (here both keep
      // their own name, so just assert order + no dupes for a repeated tool).
      expect(
        staticInstallHint(_linux('ubuntu'), ['tar', 'tar', 'rsync']),
        'sudo apt-get install -y tar rsync',
      );
    });

    test('unknown linux distro → null (caller omits the line)', () {
      expect(staticInstallHint(_linux('void'), ['tar']), isNull);
      expect(staticInstallHint(_linux(''), ['tar']), isNull);
    });
  });
}
