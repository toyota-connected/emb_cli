// Importing host_provisioner.dart transitively pulls in the macOS (brew_dart)
// and Windows (winget_dart) backends. The point of this test is that it
// resolves, analyzes, and *runs on Linux* — the regression that broke CI was
// those backends not being resolvable off their own OS. Selecting and
// constructing every backend here keeps that guarantee under test.
import 'package:emb_cli/src/host/host_info.dart';
import 'package:emb_cli/src/pkg/host_provisioner.dart';
import 'package:test/test.dart';

HostInfo _host(HostOs os) => HostInfo(
  os: os,
  machineArch: 'x86_64',
  archAliases: const {'x86_64'},
  hostType: switch (os) {
    HostOs.linux => 'ubuntu',
    HostOs.macos => 'darwin',
    HostOs.windows => 'windows',
  },
  versionId: '1',
);

void main() {
  group('HostProvisioner.forHost', () {
    test('Linux selects the PackageKit backend', () {
      // The Linux path must be unaffected by wiring in the macOS/Windows
      // backends — instantiating them must not run any native bridge.
      expect(HostProvisioner.forHost(_host(HostOs.linux)).name, 'packagekit');
    });

    test('macOS selects the Homebrew backend', () {
      expect(HostProvisioner.forHost(_host(HostOs.macos)).name, 'brew');
    });

    test('Windows selects the WinGet backend', () {
      expect(HostProvisioner.forHost(_host(HostOs.windows)).name, 'winget');
    });

    test(
      'every backend constructs on this host without touching its bridge',
      () {
        // Constructing all three on Linux must not throw: a connection/native
        // load only happens lazily on first use, on the backend's own OS.
        for (final os in HostOs.values) {
          expect(() => HostProvisioner.forHost(_host(os)), returnsNormally);
        }
      },
    );
  });
}
