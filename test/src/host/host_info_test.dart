import 'package:emb_cli/src/host/host_info.dart';
import 'package:test/test.dart';

HostInfo _fedora({String arch = 'x86_64', Set<String>? aliases}) => HostInfo(
  os: HostOs.linux,
  machineArch: arch,
  archAliases: aliases ?? {'x86_64', 'amd64', 'x64'},
  hostType: 'fedora',
  versionId: '43',
  prettyName: 'Fedora Linux 43 (Workstation Edition)',
);

void main() {
  group('parseOsRelease', () {
    test('parses key/value pairs and strips quotes', () {
      const contents = '''
NAME="Fedora Linux"
ID=fedora
VERSION_ID=43
PRETTY_NAME="Fedora Linux 43 (Workstation Edition)"
# a comment
EMPTYLINE
''';
      final map = parseOsRelease(contents);
      expect(map['NAME'], 'Fedora Linux');
      expect(map['ID'], 'fedora');
      expect(map['VERSION_ID'], '43');
      expect(map['PRETTY_NAME'], 'Fedora Linux 43 (Workstation Edition)');
      // Lines without '=' are ignored.
      expect(map.containsKey('EMPTYLINE'), isFalse);
    });

    test('handles values containing = signs', () {
      final map = parseOsRelease('FOO=a=b=c');
      expect(map['FOO'], 'a=b=c');
    });
  });

  group('flutterArch', () {
    test('maps x86_64/AMD64 to x64', () {
      expect(_fedora().flutterArch, 'x64');
      expect(_fedora(arch: 'AMD64').flutterArch, 'x64');
    });
    test('maps arm64/aarch64 to arm64', () {
      expect(_fedora(arch: 'arm64').flutterArch, 'arm64');
      expect(_fedora(arch: 'aarch64').flutterArch, 'arm64');
    });
  });

  group('matchesHostType', () {
    test('matches the distro id case-insensitively', () {
      final host = _fedora();
      expect(host.matchesHostType(['ubuntu', 'fedora']), isTrue);
      expect(host.matchesHostType(['Fedora']), isTrue);
      expect(host.matchesHostType(['ubuntu']), isFalse);
    });
  });

  group('supportsArch', () {
    test('matches via alias set', () {
      final host = _fedora();
      expect(host.supportsArch(['x86_64']), isTrue);
      expect(host.supportsArch(['x64']), isTrue);
      expect(host.supportsArch(['aarch64']), isFalse);
    });
  });
}
