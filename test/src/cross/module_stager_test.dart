import 'dart:io';

import 'package:emb_cli/src/cross/module_stager.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  late Directory build;
  late Directory lib;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('emb_mod_');
    build = Directory(p.join(tmp.path, 'build'))..createSync();
    lib = Directory(p.join(tmp.path, 'bundle', 'lib'));
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  test('stages the real file and recreates the soname symlink chain', () {
    // A typical versioned build output: real file + two symlinks beside it.
    final real = File(p.join(build.path, 'libfoo.so.1.2.3'))
      ..writeAsStringSync('ELF');
    Link(p.join(build.path, 'libfoo.so.1')).createSync('libfoo.so.1.2.3');
    Link(p.join(build.path, 'libfoo.so')).createSync('libfoo.so.1');

    final staged = stageSharedLibrary(
      soname: 'libfoo.so',
      buildDir: build,
      libDir: lib,
    );

    // The real file is copied under its own basename.
    expect(staged, isNotNull);
    expect(p.basename(staged!.path), 'libfoo.so.1.2.3');
    expect(File(p.join(lib.path, 'libfoo.so.1.2.3')).existsSync(), isTrue);
    // Every name resolves to the real file.
    for (final n in ['libfoo.so', 'libfoo.so.1']) {
      final linkPath = p.join(lib.path, n);
      expect(FileSystemEntity.isLinkSync(linkPath), isTrue);
      expect(Link(linkPath).targetSync(), 'libfoo.so.1.2.3');
      expect(File(linkPath).readAsStringSync(), 'ELF');
    }
    // The source real file is untouched (copied, not moved).
    expect(real.existsSync(), isTrue);
  });

  test('stages an unversioned single .so', () {
    File(p.join(build.path, 'libbar.so')).writeAsStringSync('ELF');
    final staged = stageSharedLibrary(
      soname: 'libbar.so',
      buildDir: build,
      libDir: lib,
    );
    expect(staged, isNotNull);
    expect(File(p.join(lib.path, 'libbar.so')).existsSync(), isTrue);
    // No spurious extra entries.
    expect(lib.listSync().map((e) => p.basename(e.path)), ['libbar.so']);
  });

  test('finds an artifact nested in a subdirectory', () {
    final sub = Directory(p.join(build.path, 'src'))..createSync();
    File(p.join(sub.path, 'libnested.so')).writeAsStringSync('ELF');
    final staged = stageSharedLibrary(
      soname: 'libnested.so',
      buildDir: build,
      libDir: lib,
    );
    expect(staged, isNotNull);
    expect(File(p.join(lib.path, 'libnested.so')).existsSync(), isTrue);
  });

  test('ignores CMake internal scratch dirs', () {
    final cmf = Directory(p.join(build.path, 'CMakeFiles', 'x.dir'))
      ..createSync(recursive: true);
    File(p.join(cmf.path, 'libfoo.so')).writeAsStringSync('scratch');
    expect(
      stageSharedLibrary(soname: 'libfoo.so', buildDir: build, libDir: lib),
      isNull,
    );
  });

  test('returns null when the declared artifact is absent', () {
    File(p.join(build.path, 'libother.so')).writeAsStringSync('ELF');
    expect(
      stageSharedLibrary(soname: 'libfoo.so', buildDir: build, libDir: lib),
      isNull,
    );
  });

  test('a similarly-named library does not match', () {
    // `libfoobar.so` must not satisfy a request for `libfoo.so`.
    File(p.join(build.path, 'libfoobar.so')).writeAsStringSync('ELF');
    expect(
      stageSharedLibrary(soname: 'libfoo.so', buildDir: build, libDir: lib),
      isNull,
    );
  });
}
