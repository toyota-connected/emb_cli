import 'dart:convert';
import 'dart:io';

import 'package:emb_cli/src/flutter/custom_devices_config.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('emb_cdc_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  group('resolveCustomDevicesConfig', () {
    test('defaults to ~/.config/flutter/custom_devices.json', () {
      final f = resolveCustomDevicesConfig(
        environment: {'HOME': tmp.path},
        operatingSystem: 'linux',
      );
      expect(
        f.path,
        p.join(tmp.path, '.config', 'flutter', 'custom_devices.json'),
      );
    });

    test(r'an existing legacy $HOME file wins', () {
      // flutter_tools prefers it when present, so emb must update the file a
      // long-lived install is actually reading.
      final legacy = File(p.join(tmp.path, '.flutter_custom_devices.json'))
        ..writeAsStringSync('{}');
      final f = resolveCustomDevicesConfig(
        environment: {'HOME': tmp.path},
        operatingSystem: 'linux',
      );
      expect(f.path, legacy.path);
    });

    test('XDG_CONFIG_HOME is used without a flutter/ segment', () {
      // Reproduces an upstream quirk: only the $HOME/.config fallback appends
      // "flutter". Adding it here would write where flutter never looks.
      final f = resolveCustomDevicesConfig(
        environment: {'HOME': tmp.path, 'XDG_CONFIG_HOME': '${tmp.path}/xdg'},
        operatingSystem: 'linux',
      );
      expect(f.path, p.join(tmp.path, 'xdg', 'custom_devices.json'));
    });

    test('windows uses %APPDATA% and the dotfile name', () {
      final f = resolveCustomDevicesConfig(
        environment: {'APPDATA': r'C:\Users\dev\AppData\Roaming'},
        operatingSystem: 'windows',
      );
      expect(p.basename(f.path), '.flutter_custom_devices.json');
      expect(f.path, contains('Roaming'));
    });

    test('macos uses ~/.config/flutter too', () {
      final f = resolveCustomDevicesConfig(
        environment: {'HOME': tmp.path},
        operatingSystem: 'macos',
      );
      expect(
        f.path,
        endsWith(p.join('.config', 'flutter', 'custom_devices.json')),
      );
    });
  });

  group('writeCustomDevice', () {
    File cfg() => File(p.join(tmp.path, 'custom_devices.json'));

    test('creates the file and its parent dirs', () {
      final f = File(p.join(tmp.path, 'nested', 'custom_devices.json'));
      final w = writeCustomDevice(f, {'id': 'rpi5', 'label': 'Pi 5'});
      expect(w.replaced, isFalse);
      expect(f.existsSync(), isTrue);
      expect(readCustomDevices(f).single['id'], 'rpi5');
    });

    test('replaces an entry with the same id rather than duplicating it', () {
      final f = cfg();
      writeCustomDevice(f, {'id': 'rpi5', 'label': 'old'});
      final w = writeCustomDevice(f, {'id': 'rpi5', 'label': 'new'});
      expect(w.replaced, isTrue);
      final devices = readCustomDevices(f);
      expect(devices, hasLength(1));
      expect(devices.single['label'], 'new');
    });

    test('preserves other devices and unrelated top-level keys', () {
      final f = cfg()
        ..writeAsStringSync(
          jsonEncode({
            r'$schema': 'https://example.com/schema.json',
            'custom-devices': [
              {'id': 'other', 'label': 'Someone else'},
            ],
          }),
        );
      writeCustomDevice(f, {'id': 'rpi5', 'label': 'Pi 5'});

      final root = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      expect(root[r'$schema'], 'https://example.com/schema.json');
      final ids = readCustomDevices(f).map((d) => d['id']).toList();
      expect(ids, ['other', 'rpi5']);
    });

    test('malformed JSON is replaced, not thrown on', () {
      // flutter treats an unusable managed config as empty rather than
      // deleting it; a write must still land.
      final f = cfg()..writeAsStringSync('{not json');
      writeCustomDevice(f, {'id': 'rpi5'});
      expect(readCustomDevices(f).single['id'], 'rpi5');
    });

    test('writes 2-space JSON with a trailing newline', () {
      final f = cfg();
      writeCustomDevice(f, {'id': 'rpi5'});
      final text = f.readAsStringSync();
      expect(text, endsWith('}\n'));
      expect(text, contains('\n  "custom-devices"'));
    });
  });

  group('readCustomDevices', () {
    test('a missing file reads as empty', () {
      expect(readCustomDevices(File(p.join(tmp.path, 'nope.json'))), isEmpty);
    });

    test('a file with no custom-devices key reads as empty', () {
      final f = File(p.join(tmp.path, 'c.json'))..writeAsStringSync('{"a":1}');
      expect(readCustomDevices(f), isEmpty);
    });
  });
}
