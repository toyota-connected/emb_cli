import 'package:emb_cli/src/cross/cross_target.dart';
import 'package:emb_cli/src/cross/custom_device_builder.dart';
import 'package:emb_cli/src/cross/deployer.dart';
import 'package:test/test.dart';

void main() {
  const spec = CustomDeviceSpec(id: 'rpi5', label: 'Raspberry Pi 5');

  Map<String, dynamic> build({
    DeployTarget device = const DeployTarget.ssh('pi@board'),
    CustomDeviceSpec s = spec,
    String deployDir = 'ivi-homescreen',
    String binName = 'homescreen',
    String? triple = 'aarch64-none-linux-gnu',
    String? targetName = 'rpi5-bookworm',
  }) => buildCustomDevice(
    spec: s,
    device: device,
    deployDir: deployDir,
    binName: binName,
    triple: triple,
    targetName: targetName,
  );

  group('metadata', () {
    test('id and label carry through, label defaults to id', () {
      expect(build()['id'], 'rpi5');
      expect(build()['label'], 'Raspberry Pi 5');
      expect(build(s: const CustomDeviceSpec(id: 'bare'))['label'], 'bare');
    });

    test('sdkNameAndVersion describes the target when unset', () {
      expect(
        build()['sdkNameAndVersion'],
        'rpi5-bookworm (aarch64-none-linux-gnu)',
      );
    });

    test('platform is derived from the triple', () {
      expect(build()['platform'], 'linux-arm64');
      expect(build(triple: 'x86_64-linux-gnu')['platform'], 'linux-x64');
    });

    test('an unsupported arch omits platform rather than guessing', () {
      // Flutter accepts only linux-x64/linux-arm64 and rejects the whole
      // config file otherwise, so armv7/riscv must leave the key out.
      expect(build(triple: 'arm-linux-gnueabihf'), isNot(contains('platform')));
      expect(build(triple: 'riscv64-linux-gnu'), isNot(contains('platform')));
    });

    test('an explicit platform overrides the derived one', () {
      // The triple would derive linux-x64; the explicit value wins.
      final e = build(
        s: const CustomDeviceSpec(id: 'x', platform: 'linux-arm64'),
        triple: 'x86_64-linux-gnu',
      );
      expect(e['platform'], 'linux-arm64');
    });

    test('enabled defaults true and can be turned off', () {
      expect(build()['enabled'], isTrue);
      expect(
        build(s: const CustomDeviceSpec(id: 'x', enabled: false))['enabled'],
        isFalse,
      );
    });

    test('forwardPort always ships its success regex', () {
      // Flutter asserts the two travel together.
      expect(build()['forwardPort'], isNotNull);
      expect(build()['forwardPortSuccessRegex'], isNotEmpty);
    });
  });

  group('ssh transport', () {
    test('ping proves the transport, not ICMP', () {
      expect(build()['ping'], [
        'ssh',
        '-o',
        'BatchMode=yes',
        'pi@board',
        'true',
      ]);
    });

    test('install clears the assets dir before copying into it', () {
      final cmd = (build()['install'] as List).cast<String>();
      expect(cmd.take(2), ['sh', '-c']);
      // The clear is what keeps an asset deleted from the app from lingering
      // on the board across a hot restart.
      expect(cmd.last, contains('rm -rf'));
      expect(cmd.last, contains('mkdir -p'));
      expect(cmd.last, contains(r"'${localPath}'/."));
      expect(cmd.last, contains('ivi-homescreen/data/flutter_assets'));
    });

    test('scp spells the port -P while ssh spells it -p', () {
      final cmd =
          (build(
                    device: const DeployTarget.ssh('pi@board', port: 2222),
                  )['install']
                  as List)[2]
              as String;
      expect(cmd, contains('ssh -o BatchMode=yes -p 2222'));
      expect(cmd, contains('-P 2222'));
    });

    test('extra ssh opts flow into every command', () {
      final e = build(
        device: const DeployTarget.ssh(
          'pi@board',
          opts: '-o StrictHostKeyChecking=no',
        ),
      );
      expect(e['ping'], contains('StrictHostKeyChecking=no'));
      expect(e['runDebug'], contains('StrictHostKeyChecking=no'));
    });

    test('runDebug launches the embedder and keeps the engineOptions slot', () {
      expect(
        (build()['runDebug'] as List).last,
        r"cd 'ivi-homescreen' && ./homescreen -b . ${engineOptions}",
      );
    });

    test('runDebug uses the configured binary name', () {
      expect(
        (build(binName: 'my-embedder')['runDebug'] as List).last,
        contains('./my-embedder -b .'),
      );
    });

    test('forwardPort holds the connection open for flutter', () {
      final cmd = (build()['forwardPort'] as List).cast<String>();
      expect(cmd, contains('-L'));
      expect(cmd, contains(r'127.0.0.1:${hostPort}:127.0.0.1:${devicePort}'));
      expect(cmd.last, contains('read'));
    });

    test('uninstall removes only the assets dir', () {
      expect(
        (build()['uninstall'] as List).last,
        "rm -rf 'ivi-homescreen/data/flutter_assets'",
      );
    });
  });

  group('adb transport', () {
    const adb = DeployTarget.adb(serial: 'ABC123');

    test('every command goes through adb with the serial', () {
      final e = build(device: adb);
      expect(e['ping'], ['adb', '-s', 'ABC123', 'shell', 'true']);
      expect((e['runDebug'] as List).take(4), ['adb', '-s', 'ABC123', 'shell']);
      expect((e['uninstall'] as List).take(4), [
        'adb',
        '-s',
        'ABC123',
        'shell',
      ]);
    });

    test('no serial omits -s', () {
      final e = build(device: const DeployTarget.adb());
      expect(e['ping'], ['adb', 'shell', 'true']);
    });

    test('install pushes into the assets dir', () {
      final cmd = (build(device: adb)['install'] as List)[2] as String;
      expect(cmd, contains('adb -s ABC123 shell'));
      expect(cmd, contains('adb -s ABC123 push'));
      expect(cmd, contains(r"'${localPath}'/."));
    });

    test('forwardPort blocks, since adb forward returns immediately', () {
      // Flutter needs a process it can hold and later kill; `adb forward`
      // alone exits at once and would look like a dead forward.
      final cmd = (build(device: adb)['forwardPort'] as List)[2] as String;
      expect(cmd, contains(r'forward tcp:${hostPort} tcp:${devicePort}'));
      expect(cmd, contains('Port forwarding success'));
      expect(cmd, contains('tail -f /dev/null'));
    });
  });

  group('validation', () {
    test('an empty id is rejected', () {
      expect(
        () => build(s: const CustomDeviceSpec(id: '  ')),
        throwsA(isA<CustomDeviceException>()),
      );
    });

    test('an empty or root deploy dir is rejected', () {
      // install would otherwise `rm -rf /data/flutter_assets`.
      for (final d in ['', '  ', '/']) {
        expect(
          () => build(deployDir: d),
          throwsA(isA<CustomDeviceException>()),
          reason: 'deployDir "$d" must be refused',
        );
      }
    });

    test('the ssh transport without a host is rejected', () {
      expect(
        () => build(device: const DeployTarget.ssh('')),
        throwsA(isA<CustomDeviceException>()),
      );
    });

    test('adb needs no host', () {
      expect(() => build(device: const DeployTarget.adb()), returnsNormally);
    });
  });

  group('CustomDeviceSpec.fromMap', () {
    test('reads the documented keys', () {
      final s = CustomDeviceSpec.fromMap({
        'id': 'rpi5',
        'label': 'Pi 5',
        'sdk_name_and_version': 'PiOS bookworm',
        'platform': 'linux-arm64',
      });
      expect(s.id, 'rpi5');
      expect(s.label, 'Pi 5');
      expect(s.sdkNameAndVersion, 'PiOS bookworm');
      expect(s.platform, 'linux-arm64');
      expect(s.enabled, isTrue);
    });

    test('enabled: false is honored', () {
      expect(
        CustomDeviceSpec.fromMap({'id': 'x', 'enabled': false}).enabled,
        isFalse,
      );
    });

    test('a target parses its custom_device block', () {
      final t = CrossTarget.fromMap(const {
        'provider': 'arm-gnu',
        'custom_device': {'id': 'rpi5', 'label': 'Pi 5'},
      });
      expect(t.customDevice?.id, 'rpi5');
    });

    test('a target without the block has none', () {
      expect(
        CrossTarget.fromMap(const {'provider': 'arm-gnu'}).customDevice,
        isNull,
      );
    });
  });
}
