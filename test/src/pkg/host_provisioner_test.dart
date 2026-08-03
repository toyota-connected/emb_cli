// Importing host_provisioner.dart transitively pulls in the macOS (brew_dart)
// and Windows (winget_dart) backends. The point of this test is that it
// resolves, analyzes, and *runs on Linux* — the regression that broke CI was
// those backends not being resolvable off their own OS. Selecting and
// constructing every backend here keeps that guarantee under test.
import 'package:emb_cli/src/host/host_info.dart';
import 'package:emb_cli/src/pkg/_platform/winget_provisioner.dart';
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

    // The interactivity flag must not silently no-op its way out of one
    // backend's interface: every backend accepts it in both states, even
    // where the underlying tool exposes no equivalent (WinGet). Without this,
    // parity drifts unnoticed because CI only exercises Linux.
    test('every backend accepts the interactive flag in both states', () {
      for (final os in HostOs.values) {
        for (final interactive in const [true, false]) {
          expect(
            () => HostProvisioner.forHost(_host(os), interactive: interactive),
            returnsNormally,
            reason: '${os.name} must accept interactive: $interactive',
          );
        }
      }
    });

    test('interactivity does not change backend selection', () {
      for (final os in HostOs.values) {
        expect(
          HostProvisioner.forHost(_host(os), interactive: false).name,
          HostProvisioner.forHost(_host(os)).name,
        );
      }
    });

    test('defaults to interactive', () {
      // Guards the default at the selection boundary, so a future signature
      // change cannot quietly make unattended the default.
      expect(
        (HostProvisioner.forHost(_host(HostOs.windows)) as WingetProvisioner)
            .interactive,
        isTrue,
      );
    });
  });
}
