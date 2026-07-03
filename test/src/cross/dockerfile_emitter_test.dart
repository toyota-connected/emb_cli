import 'package:emb_cli/src/cross/dockerfile_emitter.dart';
import 'package:test/test.dart';

void main() {
  group('ToolchainImage.dockerfile', () {
    final df = ToolchainImage.dockerfile(
      triple: 'aarch64-none-linux-gnu',
      sysrootKey: 'abc123def456',
      toolchainVersion: '12.3.rel1',
    );

    test('bakes no cross toolchain or sysroot (fetched at build time)', () {
      // The image is a build environment; the toolchain and sysroot come from
      // the shared cache / resolve, so nothing is COPY'd in.
      expect(df, isNot(contains('COPY toolchain')));
      expect(df, isNot(contains('COPY sysroot')));
      expect(df, contains('ENV FLUTTER_WORKSPACE=/emb'));
    });

    test('the build context is empty (dockerignore excludes everything)', () {
      expect(ToolchainImage.dockerignore().trim(), '*');
    });

    test('installs the host build tools and carries provenance labels', () {
      expect(df, contains('cmake'));
      expect(df, contains('ninja-build'));
      expect(df, contains('meson')); // builds augment libs (libdisplay-info)
      expect(df, contains('build-essential')); // native cc for meson configure
      expect(df, contains('hwdata')); // libdisplay-info build reads pnp.ids
      expect(df, contains('libwayland-bin')); // wayland-scanner for wayland-egl
      expect(df, contains('FROM ${ToolchainImage.defaultFrom}'));
      expect(df, contains('emb.triple="aarch64-none-linux-gnu"'));
      expect(df, contains('emb.sysroot_key="abc123def456"'));
      expect(df, contains('emb.toolchain_version="12.3.rel1"'));
    });

    test('honors a custom base image', () {
      final u = ToolchainImage.dockerfile(
        triple: 't',
        sysrootKey: 'k',
        fromImage: 'ubuntu:24.04',
      );
      expect(u, contains('FROM ubuntu:24.04'));
    });

    test('host_dev_packages: added to the apt install when given', () {
      // Absent by default (no manifest host_dev_packages).
      expect(df, isNot(contains('libpugixml-dev')));
      final withDev = ToolchainImage.dockerfile(
        triple: 't',
        sysrootKey: 'k',
        hostDevPackages: ['libpugixml-dev'],
      );
      expect(withDev, contains('libpugixml-dev'));
      // Still part of the single apt-get install (ends with the cache cleanup).
      expect(withDev, contains('rm -rf /var/lib/apt/lists/*'));
    });
  });

  group('ToolchainImage.imageTag', () {
    test('is <sysrootKey>-<12 hex toolset hash>', () {
      final tag = ToolchainImage.imageTag(
        triple: 'aarch64-none-linux-gnu',
        sysrootKey: '809d8bb7bb71',
        toolchainVersion: '12.3.rel1',
      );
      expect(tag, matches(RegExp(r'^809d8bb7bb71-[0-9a-f]{12}$')));
    });

    test('stable for same inputs; a toolset change rekeys, prefix kept', () {
      String tag({String from = ToolchainImage.defaultFrom}) =>
          ToolchainImage.imageTag(
            triple: 't',
            sysrootKey: 'KEY',
            fromImage: from,
          );
      expect(tag(), tag()); // deterministic
      // A different baked toolset (base image) -> different suffix, same key.
      expect(tag(from: 'ubuntu:24.04'), isNot(tag()));
      expect(tag().startsWith('KEY-'), isTrue);
      expect(tag(from: 'ubuntu:24.04').startsWith('KEY-'), isTrue);
    });

    test('host_dev_packages rekey the tag (so the image rebuilds)', () {
      String tag(List<String> dev) => ToolchainImage.imageTag(
        triple: 't',
        sysrootKey: 'KEY',
        hostDevPackages: dev,
      );
      expect(tag(const []), isNot(tag(['libpugixml-dev'])));
      expect(tag(['libpugixml-dev']).startsWith('KEY-'), isTrue);
    });
  });
}
