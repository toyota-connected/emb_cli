import 'package:emb_cli/src/cross/apt_snapshot.dart';
import 'package:test/test.dart';

void main() {
  group('snapshotTimestamp', () {
    test('expands a bare date to midnight UTC', () {
      expect(snapshotTimestamp('2024-06-01'), '20240601T000000Z');
    });
    test('accepts a date with a time', () {
      expect(snapshotTimestamp('2024-06-01 12:30:45'), '20240601T123045Z');
    });
    test('passes an already-normalized stamp through', () {
      expect(snapshotTimestamp('20240601T000000Z'), '20240601T000000Z');
    });
    test('returns null for an unparseable date', () {
      expect(snapshotTimestamp('June 2024'), isNull);
      expect(snapshotTimestamp('2024/06/01'), isNull);
    });
  });

  group('snapshotRewrite', () {
    const ts = '20240601T000000Z';

    test('rewrites a Debian mirror index URL to snapshot.debian.org', () {
      expect(
        snapshotRewrite(
          'http://deb.debian.org/debian/dists/bookworm/main/binary-arm64/Packages.xz',
          ts,
        ),
        'https://snapshot.debian.org/archive/debian/$ts'
        '/dists/bookworm/main/binary-arm64/Packages.xz',
      );
    });

    test('rewrites debian-security to its own snapshot archive', () {
      expect(
        snapshotRewrite(
          'http://security.debian.org/debian-security/dists/bookworm-security/main/binary-arm64/Packages.xz',
          ts,
        ),
        startsWith(
          'https://snapshot.debian.org/archive/debian-security/$ts/dists/',
        ),
      );
    });

    test('rewrites a raspbian mirror to snapshot.raspbian.org', () {
      expect(
        snapshotRewrite(
          'http://raspbian.raspberrypi.org/raspbian/dists/bookworm/main/binary-armhf/Packages.xz',
          ts,
        ),
        startsWith('http://snapshot.raspbian.org/raspbian/$ts/dists/'),
      );
    });

    test('returns null for a mirror with no known snapshot service', () {
      expect(
        snapshotRewrite(
          'http://archive.raspberrypi.org/debian/dists/bookworm/main/binary-armhf/Packages.xz',
          ts,
        ),
        isNull,
      );
    });

    test('does not match a lookalike host as a prefix', () {
      // A host that merely starts with the same string but diverges.
      expect(
        snapshotRewrite(
          'http://deb.debian.org.evil.com/debian/dists/x/main/binary-arm64/Packages.xz',
          ts,
        ),
        isNull,
      );
    });
  });
}
