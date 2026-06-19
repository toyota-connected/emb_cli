import 'package:emb_cli/src/cross/dockerfile_emitter.dart';
import 'package:test/test.dart';

void main() {
  group('ToolchainImage.dockerfile', () {
    final df = ToolchainImage.dockerfile(
      triple: 'aarch64-none-linux-gnu',
      sysrootKey: 'abc123def456',
      toolchainVersion: '12.3.rel1',
    );

    test('bakes toolchain + sysroot at the keyed platform dir under /emb', () {
      const dir =
          '/emb/.config/flutter_workspace/'
          'cross-aarch64-none-linux-gnu-abc123def456';
      expect(df, contains('COPY toolchain $dir/toolchain'));
      expect(df, contains('COPY sysroot $dir/sysroot'));
      expect(df, contains('ENV FLUTTER_WORKSPACE=/emb'));
    });

    test('installs the host build tools and carries provenance labels', () {
      expect(df, contains('cmake'));
      expect(df, contains('ninja-build'));
      expect(df, contains('meson')); // builds augment libs (libdisplay-info)
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
  });

  test('dockerignore keeps only toolchain + sysroot in the context', () {
    final di = ToolchainImage.dockerignore();
    expect(di, contains('*'));
    expect(di, contains('!toolchain'));
    expect(di, contains('!sysroot'));
  });

  test('dockerignore slims the sysroot but keeps build-essential trees', () {
    final di = ToolchainImage.dockerignore();
    // Drops device-rootfs bloat (data, apps, kernel/firmware, target bins).
    expect(di, contains('sysroot/usr/share/locale'));
    expect(di, contains('sysroot/usr/share/doc'));
    expect(di, contains('sysroot/usr/lib/firmware'));
    expect(di, contains('sysroot/usr/bin'));
    expect(di, contains('sysroot/boot'));
    // Never prunes headers, libraries, or pkgconfig/cmake/wayland metadata.
    expect(di, isNot(contains('sysroot/usr/include')));
    expect(di, isNot(contains('sysroot/usr/lib/aarch64')));
    expect(di, isNot(contains('sysroot/usr/share/pkgconfig')));
    expect(di, isNot(contains('sysroot/usr/share/wayland')));
  });
}
