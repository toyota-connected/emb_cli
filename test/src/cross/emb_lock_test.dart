import 'dart:io';

import 'package:emb_cli/src/cross/emb_lock.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

LockedTarget _armGnu({
  String version = '12.3.rel1',
  String? codename,
  String tcSha = 'tc-sha',
  String imgSha = 'img-sha',
  String sysrootKey = 'key1',
  String buildKey = 'key2',
}) => LockedTarget(
  provider: 'arm-gnu',
  triple: 'aarch64-none-linux-gnu',
  toolchainVersion: version,
  codename: codename,
  sysrootKey: sysrootKey,
  buildKey: buildKey,
  artifacts: [
    LockedArtifact(
      kind: ArtifactKind.toolchain,
      url: 'https://example.com/tc.tar.xz',
      sha256: tcSha,
    ),
    LockedArtifact(
      kind: ArtifactKind.image,
      url: 'https://example.com/os.img.xz',
      sha256: imgSha,
    ),
  ],
);

void main() {
  group('round-trip', () {
    test('encode then parse preserves a target', () {
      final lock = EmbLock().withTarget('rpi5', _armGnu(codename: 'bookworm'));
      final back = EmbLock.parse(lock.encode());

      expect(back.version, EmbLock.currentVersion);
      final t = back.targets['rpi5']!;
      expect(t.provider, 'arm-gnu');
      expect(t.triple, 'aarch64-none-linux-gnu');
      expect(t.toolchainVersion, '12.3.rel1');
      expect(t.codename, 'bookworm');
      expect(t.sysrootKey, 'key1');
      expect(t.buildKey, 'key2');
      expect(t.artifacts, hasLength(2));
      final tc = t.artifacts.firstWhere(
        (a) => a.kind == ArtifactKind.toolchain,
      );
      expect(tc.url, 'https://example.com/tc.tar.xz');
      expect(tc.sha256, 'tc-sha');
    });

    test('encoding is deterministic and sorted regardless of insert order', () {
      final a = EmbLock()
          .withTarget('zzz', _armGnu())
          .withTarget('aaa', _armGnu());
      final b = EmbLock()
          .withTarget('aaa', _armGnu())
          .withTarget('zzz', _armGnu());
      expect(a.encode(), b.encode());
      // aaa sorts before zzz in the output.
      expect(a.encode().indexOf('aaa'), lessThan(a.encode().indexOf('zzz')));
    });

    test('an empty lock encodes and parses', () {
      final lock = EmbLock();
      expect(lock.encode(), contains('targets: {}'));
      expect(EmbLock.parse(lock.encode()).targets, isEmpty);
    });

    test('device artifact carries host, no sha', () {
      final lock = EmbLock().withTarget(
        'unoq',
        const LockedTarget(
          provider: 'arm-gnu',
          triple: 'aarch64-none-linux-gnu',
          sysrootKey: 'k1',
          buildKey: 'k2',
          artifacts: [
            LockedArtifact(kind: ArtifactKind.device, host: 'root@unoq.local'),
          ],
        ),
      );
      final back = EmbLock.parse(lock.encode()).targets['unoq']!;
      final dev = back.artifacts.single;
      expect(dev.kind, ArtifactKind.device);
      expect(dev.host, 'root@unoq.local');
      expect(dev.sha256, isNull);
    });
  });

  group('driftAgainst', () {
    test('identical resolution has no drift', () {
      expect(_armGnu().driftAgainst(_armGnu()), isEmpty);
    });

    test('a moved URL (changed sha) is reported', () {
      final drift = _armGnu().driftAgainst(_armGnu(imgSha: 'c' * 64));
      expect(drift, hasLength(1));
      expect(drift.single, contains('image sha256 mismatch'));
    });

    test('a drifted derived toolchain version is reported', () {
      final drift = _armGnu().driftAgainst(_armGnu(version: '13.2.rel1'));
      expect(drift.single, contains('toolchain_version'));
    });

    test('changed input keys point at --update-lock', () {
      final drift = _armGnu().driftAgainst(_armGnu(sysrootKey: 'other'));
      expect(drift.single, contains('--update-lock'));
    });

    test('an artifact not re-materialized this run is skipped', () {
      // resolved has no artifacts (e.g. fully cached, image pruned) → no sha to
      // compare → no drift.
      const resolved = LockedTarget(
        provider: 'arm-gnu',
        triple: 'aarch64-none-linux-gnu',
        toolchainVersion: '12.3.rel1',
        sysrootKey: 'key1',
        buildKey: 'key2',
      );
      expect(_armGnu().driftAgainst(resolved), isEmpty);
    });
  });

  group('reconcileLock', () {
    test('no existing lock → wrote (auto-create)', () {
      final r = reconcileLock(
        existing: null,
        target: 'rpi5',
        resolved: _armGnu(),
        updateLock: false,
        verify: true,
      );
      expect(r.action, LockAction.wrote);
      expect(r.lock!.targets['rpi5']!.toolchainVersion, '12.3.rel1');
    });

    test('existing matching entry → verified', () {
      final existing = EmbLock().withTarget('rpi5', _armGnu());
      final r = reconcileLock(
        existing: existing,
        target: 'rpi5',
        resolved: _armGnu(),
        updateLock: false,
        verify: true,
      );
      expect(r.action, LockAction.verified);
    });

    test('drifted sha → drifted with problems', () {
      final existing = EmbLock().withTarget('rpi5', _armGnu());
      final r = reconcileLock(
        existing: existing,
        target: 'rpi5',
        resolved: _armGnu(imgSha: 'moved'),
        updateLock: false,
        verify: true,
      );
      expect(r.action, LockAction.drifted);
      expect(r.problems.single, contains('sha256 mismatch'));
    });

    test('--update-lock rewrites a drifted entry instead of failing', () {
      final existing = EmbLock().withTarget('rpi5', _armGnu());
      final r = reconcileLock(
        existing: existing,
        target: 'rpi5',
        resolved: _armGnu(imgSha: 'moved'),
        updateLock: true,
        verify: true,
      );
      expect(r.action, LockAction.wrote);
      final img = r.lock!.targets['rpi5']!.artifacts.firstWhere(
        (a) => a.kind == ArtifactKind.image,
      );
      expect(img.sha256, 'moved');
    });

    test('--no-verify skips a drift that would otherwise fail', () {
      final existing = EmbLock().withTarget('rpi5', _armGnu());
      final r = reconcileLock(
        existing: existing,
        target: 'rpi5',
        resolved: _armGnu(imgSha: 'moved'),
        updateLock: false,
        verify: false,
      );
      expect(r.action, LockAction.verified);
    });

    test('--update-lock preserves other targets in the lock', () {
      final existing = EmbLock()
          .withTarget('rpi5', _armGnu())
          .withTarget('rpi4', _armGnu());
      final r = reconcileLock(
        existing: existing,
        target: 'rpi5',
        resolved: _armGnu(version: '13.2.rel1'),
        updateLock: true,
        verify: true,
      );
      expect(r.lock!.targets.keys, containsAll(['rpi5', 'rpi4']));
      expect(r.lock!.targets['rpi5']!.toolchainVersion, '13.2.rel1');
    });
  });

  group('load', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('emb_lock_'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test('load returns null when the file is absent', () {
      expect(EmbLock.load(File(p.join(tmp.path, 'emb.lock'))), isNull);
    });

    test('save then load round-trips through disk', () {
      final file = File(p.join(tmp.path, 'emb.lock'));
      EmbLock().withTarget('rpi5', _armGnu()).save(file);
      final loaded = EmbLock.load(file)!;
      expect(loaded.targets.keys, ['rpi5']);
      expect(loaded.targets['rpi5']!.toolchainVersion, '12.3.rel1');
    });

    test('a malformed document throws FormatException', () {
      expect(() => EmbLock.parse('- not\n- a\n- map'), throwsFormatException);
    });
  });
}
