import 'package:emb_cli/src/engine/engine_artifacts.dart';
import 'package:emb_cli/src/host/host_info.dart';
import 'package:test/test.dart';

void main() {
  group('engineArch', () {
    test('maps x64/x86_64/amd64 to x86_64', () {
      expect(EngineArtifacts.engineArch('x64'), 'x86_64');
      expect(EngineArtifacts.engineArch('x86_64'), 'x86_64');
      expect(EngineArtifacts.engineArch('AMD64'), 'x86_64');
    });
    test('maps arm/armv7hf to armv7hf', () {
      expect(EngineArtifacts.engineArch('arm'), 'armv7hf');
      expect(EngineArtifacts.engineArch('armv7hf'), 'armv7hf');
    });
    test('maps arm64/aarch64 to arm64', () {
      expect(EngineArtifacts.engineArch('arm64'), 'arm64');
      expect(EngineArtifacts.engineArch('aarch64'), 'arm64');
    });
    test('passes through riscv64', () {
      expect(EngineArtifacts.engineArch('riscv64'), 'riscv64');
    });
  });

  group('engineArchForHost', () {
    test('resolves the engine token from the host machine arch', () {
      const host = HostInfo(
        os: HostOs.linux,
        machineArch: 'aarch64',
        archAliases: {'aarch64', 'arm64'},
        hostType: 'fedora',
        versionId: '43',
      );
      expect(EngineArtifacts.engineArchForHost(host), 'arm64');
    });
  });

  group('engineSdkUrl', () {
    test('builds the meta-flutter release URL', () {
      final url = EngineArtifacts.engineSdkUrl('release', 'x64', 'abc123');
      expect(
        url,
        'https://github.com/meta-flutter/flutter-engine/releases/download/'
        'linux-engine-sdk-release-x86_64-abc123/'
        'linux-engine-sdk-release-x86_64-abc123.tar.gz',
      );
    });

    test('uses the mapped arch token', () {
      final url = EngineArtifacts.engineSdkUrl('debug', 'arm', 'deadbeef');
      expect(url, contains('linux-engine-sdk-debug-armv7hf-deadbeef'));
    });
  });
}
