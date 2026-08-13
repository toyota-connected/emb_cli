import 'package:emb_cli/src/engine/engine_toolchain.dart';
import 'package:test/test.dart';

void main() {
  group('ToolchainProfile.storeKey', () {
    test('linux/glibc omits sysroot and compiler', () {
      expect(
        ToolchainProfile.linuxGlibc.storeKey(
          commit: 'abc123',
          arch: 'arm64',
          mode: 'release',
        ),
        'abc123-linux-arm64-release-glibc',
      );
    });

    test('musl folds in the sysroot flavour', () {
      const musl = ToolchainProfile(
        os: TargetOs.linux,
        libc: Libc.musl,
        sysrootId: 'poky',
      );
      expect(
        musl.storeKey(commit: 'abc', arch: 'arm64', mode: 'profile'),
        'abc-linux-arm64-profile-musl-poky',
      );
    });

    test('a non-default compiler appears in the key', () {
      const p = ToolchainProfile(
        os: TargetOs.linux,
        libc: Libc.glibc,
        compilerId: 'meta-clang-17',
      );
      expect(
        p.storeKey(commit: 'c', arch: 'x86_64', mode: 'debug'),
        'c-linux-x86_64-debug-glibc-meta-clang-17',
      );
    });
  });

  group('Libc.fromToken', () {
    test('accepts glibc/gnu, musl, bionic/android', () {
      expect(Libc.fromToken('glibc'), Libc.glibc);
      expect(Libc.fromToken('GNU'), Libc.glibc);
      expect(Libc.fromToken('musl'), Libc.musl);
      expect(Libc.fromToken('android'), Libc.bionic);
    });

    test('rejects an unknown token', () {
      expect(() => Libc.fromToken('nope'), throwsArgumentError);
    });
  });
}
