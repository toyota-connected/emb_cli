import 'package:emb_cli/src/exec/exec_env.dart';
import 'package:emb_cli/src/host/host_info.dart';
import 'package:test/test.dart';

HostInfo _host(HostOs os, String arch) => HostInfo(
  os: os,
  machineArch: arch,
  archAliases: const {},
  hostType: os.name,
  versionId: '1',
);

void main() {
  const image = 'ghcr.io/acme/emb-engine-builder:latest';

  test('linux x86_64 host runs native', () {
    expect(
      resolveExecEnv(_host(HostOs.linux, 'x86_64'), image: image),
      isA<NativeExec>(),
    );
  });

  test('macOS host routes to the container', () {
    final env = resolveExecEnv(_host(HostOs.macos, 'arm64'), image: image);
    expect(env, isA<ContainerExec>());
    expect((env as ContainerExec).reason, contains('not linux'));
    expect(env.image, image);
  });

  test('linux non-x86_64 host routes to the container', () {
    final env = resolveExecEnv(_host(HostOs.linux, 'arm64'), image: image);
    expect(env, isA<ContainerExec>());
    expect((env as ContainerExec).reason, contains('not x86_64'));
  });

  test('inContainer guard forces native (no recursion)', () {
    expect(
      resolveExecEnv(
        _host(HostOs.macos, 'arm64'),
        image: image,
        inContainer: true,
      ),
      isA<NativeExec>(),
    );
  });

  test('forceNative overrides the routing', () {
    expect(
      resolveExecEnv(
        _host(HostOs.windows, 'x86_64'),
        image: image,
        forceNative: true,
      ),
      isA<NativeExec>(),
    );
  });
}
