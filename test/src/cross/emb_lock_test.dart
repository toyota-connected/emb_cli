import 'dart:io';

import 'package:emb_cli/src/cross/emb_lock.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

LockedTarget _armGnu({
  String version = '12.3.rel1',
  String? codename,
  String? compilerVersion,
  String tcSha = 'tc-sha',
  String imgSha = 'img-sha',
  String sysrootKey = 'key1',
  String buildKey = 'key2',
}) => LockedTarget(
  provider: 'arm-gnu',
  triple: 'aarch64-none-linux-gnu',
  toolchainVersion: version,
  codename: codename,
  compilerVersion: compilerVersion,
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

    test('a drifted compiler version is reported and round-trips', () {
      final locked = _armGnu(compilerVersion: '12.3.0');
      expect(
        EmbLock.parse(
          EmbLock().withTarget('t', locked).encode(),
        ).targets['t']!.compilerVersion,
        '12.3.0',
      );
      final drift = locked.driftAgainst(_armGnu(compilerVersion: '13.2.0'));
      expect(drift.single, contains('compiler_version'));
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

  group('lockKey', () {
    test('a flat manifest file qualifies the target with its stem', () {
      expect(
        lockKey(
          inputPath: '/w/pi5.emb.yaml',
          isDirectory: false,
          target: 'pi5',
        ),
        'pi5:pi5',
      );
      expect(
        lockKey(
          inputPath: '/w/board-a.emb.yaml',
          isDirectory: false,
          target: 'rpi5-bookworm',
        ),
        'board-a:rpi5-bookworm',
      );
    });

    test('a project directory uses the bare target', () {
      expect(
        lockKey(inputPath: '/w/proj', isDirectory: true, target: 'rpi5'),
        'rpi5',
      );
    });

    test('two co-located flat manifests get distinct lock keys', () {
      // Same directory, same resolved target name → the stems disambiguate.
      final a = lockKey(
        inputPath: '/w/a.emb.yaml',
        isDirectory: false,
        target: 'pi5',
      );
      final b = lockKey(
        inputPath: '/w/b.emb.yaml',
        isDirectory: false,
        target: 'pi5',
      );
      expect(a, isNot(b));
      // They coexist as independent entries in one shared document.
      final lock = EmbLock().withTarget(a, _armGnu()).withTarget(b, _armGnu());
      expect(lock.targets.keys, containsAll([a, b]));
      final reloaded = EmbLock.parse(lock.encode());
      expect(reloaded.targets.keys, containsAll([a, b]));
    });
  });

  group('package pins', () {
    LockedTarget withPkgs(List<LockedPackage> pkgs) => LockedTarget(
      provider: 'arm-gnu',
      triple: 'aarch64-none-linux-gnu',
      sysrootKey: 'k1',
      buildKey: 'k2',
      packages: pkgs,
    );

    test('packages round-trip through encode/parse, sorted by name', () {
      final lock = EmbLock().withTarget(
        'rpi5',
        withPkgs(const [
          LockedPackage(name: 'libdrm-dev', version: '2.4.120', sha256: 'aa'),
          LockedPackage(name: 'libc6-dev', version: '2.36', sha256: 'bb'),
        ]),
      );
      final pkgs = EmbLock.parse(lock.encode()).targets['rpi5']!.packages;
      expect(pkgs.map((p) => p.name), ['libc6-dev', 'libdrm-dev']);
      expect(pkgs.first.version, '2.36');
    });

    test('a changed package version is reported as drift', () {
      final locked = withPkgs(const [
        LockedPackage(name: 'libdrm-dev', version: '2.4.120'),
      ]);
      final resolved = withPkgs(const [
        LockedPackage(name: 'libdrm-dev', version: '2.4.121'),
      ]);
      final problems = locked.driftAgainst(resolved);
      expect(problems, hasLength(1));
      expect(problems.single, contains('libdrm-dev'));
      expect(problems.single, contains('2.4.121'));
    });

    test('an unchanged version is not drift', () {
      final t = withPkgs(const [
        LockedPackage(name: 'libdrm-dev', version: '2.4.120'),
      ]);
      expect(t.driftAgainst(t), isEmpty);
    });
  });

  group('env self-pins', () {
    test('round-trip through encode/parse', () {
      final lock = EmbLock()
          .withEnv(
            const LockEnv(
              embVersion: '0.1.0',
              engineCommit: 'deadbeef',
              flutterCommit: 'cafe',
              rustcVersion: 'rustc 1.79.0',
            ),
          )
          .withTarget('rpi5', _armGnu());
      final env = EmbLock.parse(lock.encode()).env;
      expect(env.embVersion, '0.1.0');
      expect(env.engineCommit, 'deadbeef');
      expect(env.flutterCommit, 'cafe');
      expect(env.rustcVersion, 'rustc 1.79.0');
    });

    test('an empty env writes no env block', () {
      final encoded = EmbLock().withTarget('rpi5', _armGnu()).encode();
      expect(encoded, isNot(contains('env:')));
    });

    test('withTarget preserves the env', () {
      final lock = EmbLock()
          .withEnv(const LockEnv(embVersion: '0.1.0'))
          .withTarget('a', _armGnu());
      expect(lock.env.embVersion, '0.1.0');
    });
  });
}
