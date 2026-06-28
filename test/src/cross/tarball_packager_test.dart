import 'dart:io';

import 'package:emb_cli/src/cross/tarball_packager.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('emb_targz_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  File fakeBinary() =>
      File(p.join(tmp.path, 'homescreen'))
        ..writeAsBytesSync([0x7f, 0x45, 0x4c, 0x46, 0, 0, 0, 0]);

  // Uses the real `tar`, then inspects the archive with `tar -tzf`.
  test('builds a .tar.gz containing the binary at its install path', () async {
    final cfg = File(p.join(tmp.path, 'app.toml'))..writeAsStringSync('x');
    final packager = TarballPackager();
    final out = await packager.build(
      binary: fakeBinary(),
      installPath: '/usr/bin/homescreen',
      meta: const TarballMetadata(
        name: 'ivi-homescreen',
        version: '1.0.0',
        architecture: 'aarch64',
      ),
      outDir: Directory(p.join(tmp.path, 'dist')),
      extraFiles: {cfg.path: '/etc/ivi/app.toml'},
    );

    expect(out.path, endsWith('ivi-homescreen_1.0.0_aarch64.tar.gz'));
    expect(out.existsSync(), isTrue);
    final listing = Process.runSync('tar', ['-tzf', out.path]).stdout as String;
    final entries = listing.split('\n');
    // Paths are relative to the target root (./usr/bin/…, ./etc/…).
    expect(entries, contains('./usr/bin/homescreen'));
    expect(entries, contains('./etc/ivi/app.toml'));
  }, skip: _noTar());

  test('rejects a relative install path', () async {
    final packager = TarballPackager();
    expect(
      () => packager.build(
        binary: fakeBinary(),
        installPath: 'usr/bin/homescreen',
        meta: const TarballMetadata(
          name: 'app',
          version: '1',
          architecture: 'aarch64',
        ),
        outDir: Directory(p.join(tmp.path, 'dist')),
      ),
      throwsA(isA<TarballPackageException>()),
    );
  });
}

/// Skip reason when `tar` is unavailable (it is virtually always present).
String? _noTar() {
  try {
    return Process.runSync('tar', ['--version']).exitCode == 0
        ? null
        : 'tar not runnable';
  } catch (_) {
    return 'tar not installed';
  }
}
