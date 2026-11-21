import 'package:emb_cli/src/cross/cross_profile.dart';
import 'package:emb_cli/src/cross/local_cross_provider.dart';
import 'package:emb_cli/src/host/host_info.dart';
import 'package:test/test.dart';

const _linux = HostInfo(
  os: HostOs.linux,
  machineArch: 'x86_64',
  archAliases: {'x86_64', 'x64', 'amd64'},
  hostType: 'fedora',
  versionId: '43',
);

void main() {
  test('resolves a native profile with no toolchain file or sysroot', () async {
    final r = await LocalCrossProvider(_linux).resolve();
    expect(r.ok, isTrue);
    final pf = r.profile!;
    expect(pf.providerName, 'local');
    expect(pf.cmakeToolchainFile, isNull);
    expect(pf.targetSysroot, isEmpty);
    expect(pf.targetTriple, 'x86_64-linux-gnu');
  });

  test(
    'is host-built, host-runnable, and keeps augments in an overlay',
    () async {
      final pf = (await LocalCrossProvider(_linux).resolve()).profile!;
      expect(pf.hostToolchain, isTrue);
      expect(pf.separateOverlay, isTrue);
      expect(pf.hostRunnable, isTrue);

      // An emitted toolchain file must not drop them.
      final withTc = pf.withGenerators(cmakeToolchainFile: '/tc.cmake');
      expect(withTc.hostToolchain, isTrue);
      expect(withTc.separateOverlay, isTrue);
      expect(withTc.hostRunnable, isTrue);
    },
  );

  test('a cross profile defaults to none of them', () {
    const pf = CrossProfile(
      providerName: 'arm-gnu',
      targetTriple: 'aarch64-none-linux-gnu',
      cc: 'gcc',
      cxx: 'g++',
      ar: 'ar',
      strip: 'strip',
      targetSysroot: '/sysroot',
    );
    expect(pf.hostToolchain, isFalse);
    expect(pf.separateOverlay, isFalse);
    expect(pf.hostRunnable, isFalse);
  });

  test('triple + debArch reflect the host', () {
    final lp = LocalCrossProvider(_linux);
    expect(lp.triple, 'x86_64-linux-gnu');
    expect(lp.debArch, 'amd64');
    expect(lp.preflightTools, isEmpty);
  });

  test('unavailable on a non-Linux host', () async {
    const mac = HostInfo(
      os: HostOs.macos,
      machineArch: 'arm64',
      archAliases: {'arm64'},
      hostType: 'macos',
      versionId: '14',
    );
    final r = await LocalCrossProvider(mac).resolve();
    expect(r.status, CrossResolveStatus.unavailable);
  });
}
