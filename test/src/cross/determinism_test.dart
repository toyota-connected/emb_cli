import 'package:emb_cli/src/cross/determinism.dart';
import 'package:test/test.dart';

void main() {
  group('sourceDateEpoch', () {
    test('parses a valid epoch', () {
      expect(sourceDateEpoch({'SOURCE_DATE_EPOCH': '1700000000'}), 1700000000);
    });
    test('is null when unset', () {
      expect(sourceDateEpoch(const {}), isNull);
    });
    test('is null for a non-numeric or negative value', () {
      expect(sourceDateEpoch({'SOURCE_DATE_EPOCH': 'nope'}), isNull);
      expect(sourceDateEpoch({'SOURCE_DATE_EPOCH': '-5'}), isNull);
    });
  });

  group('toolchainPrefixMap', () {
    test('maps the cross sysroot and toolchain bin to stable tokens', () {
      final m = toolchainPrefixMap(
        sysroot: '/home/u/.cache/emb/sysroots/rpi',
        crossBin: '/home/u/.cache/emb/tc/bin',
      );
      expect(m['/home/u/.cache/emb/sysroots/rpi'], '/emb/sysroot');
      expect(m['/home/u/.cache/emb/tc/bin'], '/emb/toolchain');
    });

    test('is empty for a native build (no target sysroot)', () {
      expect(toolchainPrefixMap(sysroot: '', crossBin: '/usr/bin'), isEmpty);
    });
  });

  group('flag rendering', () {
    final map = {'/sr': '/emb/sysroot'};
    test('prefixMapFlags emits file and debug prefix maps', () {
      expect(prefixMapFlags(map), [
        '-ffile-prefix-map=/sr=/emb/sysroot',
        '-fdebug-prefix-map=/sr=/emb/sysroot',
      ]);
    });
    test('rustRemapArgs emits one remap per entry', () {
      expect(rustRemapArgs(map), ['--remap-path-prefix=/sr=/emb/sysroot']);
    });
  });
}
