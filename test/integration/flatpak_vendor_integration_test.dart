@Tags(['flatpak'])
library;

import 'dart:io';

import 'package:emb_cli/src/cross/elf_check.dart';
import 'package:emb_cli/src/cross/flatpak_vendor.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Drives [FlatpakLibVendor] against a real installed flatpak runtime and the
/// host `readelf`.
///
/// The unit tests fake `readelf` entirely, which is right for asserting the
/// decisions and blind to the two things only real inputs settle: that
/// `_indexRuntime` finds libraries where an actual runtime puts them, and that
/// the `readelf -V` parsers handle the output of the binutils on the machine.
/// The second is the likelier to rot — readelf's format is not a stable
/// interface, and a silently empty parse makes the symbol-version check report
/// nothing rather than fail.
///
/// Gap *detection* is not asserted here. Whether a host library needs a symbol
/// version the runtime lacks depends on the host's glibc versus the runtime's,
/// so an assertion either way would pass or fail on which runner picked up the
/// job. That logic is pinned in `test/src/cross/flatpak_vendor_test.dart` with
/// the versions controlled; this checks it runs against real files and reports
/// something well-formed.
void main() {
  late Directory tmp;
  Directory? runtimeFiles;
  String? branch;

  setUpAll(() async {
    final list = await Process.run('flatpak', [
      'list',
      '--runtime',
      '--columns=application,branch',
    ]);
    if (list.exitCode != 0) return;
    final branches = <String>[];
    for (final line in (list.stdout as String).split('\n')) {
      final parts = line.trim().split(RegExp(r'\s+'));
      if (parts.length >= 2 && parts[0] == 'org.freedesktop.Platform') {
        branches.add(parts[1]);
      }
    }
    if (branches.isEmpty) return;
    branches.sort();
    branch = branches.last;
    final loc = await Process.run('flatpak', [
      'info',
      '--show-location',
      'org.freedesktop.Platform//${branch!}',
    ]);
    if (loc.exitCode != 0) return;
    final dir = Directory(p.join((loc.stdout as String).trim(), 'files'));
    if (dir.existsSync()) runtimeFiles = dir;
  });

  setUp(() => tmp = Directory.systemTemp.createTempSync('emb_fpv_it_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  /// The runtime's own libc, wherever this runtime puts it.
  File? runtimeLibc() {
    final root = runtimeFiles;
    if (root == null) return null;
    for (final rel in ['lib', 'lib64', 'usr/lib']) {
      final d = Directory(p.join(root.path, rel));
      if (!d.existsSync()) continue;
      for (final e in d.listSync(recursive: true, followLinks: false)) {
        if (e is File && p.basename(e.path) == 'libc.so.6') return e;
      }
    }
    return null;
  }

  test('the version-definition parser reads a real runtime libc', () async {
    final libc = runtimeLibc();
    if (libc == null) {
      markTestSkipped('no org.freedesktop.Platform runtime installed');
      return;
    }
    final r = await Process.run('readelf', ['-V', libc.path]);
    expect(r.exitCode, 0, reason: 'readelf could not read ${libc.path}');
    final defs = parseVersionDefs(r.stdout as String);
    // An empty parse is the failure that matters: the symbol-version check
    // treats "no definitions" as "nothing known" and goes quiet, so a format
    // change would disable it silently rather than break a test.
    expect(
      defs,
      isNotEmpty,
      reason:
          'parsed no symbol versions from a real libc — the check would '
          'silently stop reporting anything',
    );
    expect(
      defs.where((d) => d.startsWith('GLIBC_')),
      isNotEmpty,
      reason: 'a libc defines GLIBC_* versions; got $defs',
    );
  });

  test('the version-needs parser reads a real host binary', () async {
    // A binary, not a library: `.gnu.version_r` is what needs parsing, and
    // every dynamically linked host binary has one aimed at libc.
    final sh = File('/bin/sh');
    if (!sh.existsSync()) {
      markTestSkipped('no /bin/sh to read');
      return;
    }
    final r = await Process.run('readelf', [
      '-V',
      sh.resolveSymbolicLinksSync(),
    ]);
    expect(r.exitCode, 0);
    final needs = parseVersionNeeds(r.stdout as String);
    expect(needs.keys, contains('libc.so.6'));
    expect(needs['libc.so.6'], isNotEmpty);
  });

  test('a real runtime provides libc, so it is not vendored', () async {
    final root = runtimeFiles;
    if (root == null) {
      markTestSkipped('no org.freedesktop.Platform runtime installed');
      return;
    }
    // A host binary as the stand-in embedder: it is really dynamically linked,
    // so the closure walk has something true to follow.
    final bundle = Directory(p.join(tmp.path, 'runnable'))
      ..createSync(recursive: true);
    File('/bin/cat').copySync(p.join(bundle.path, 'homescreen'));
    Directory(p.join(bundle.path, 'lib')).createSync();

    final report =
        await FlatpakLibVendor(
          readelf: 'readelf',
          triple: 'x86_64-linux-gnu',
        ).vendor(
          bundleDir: bundle,
          command: 'homescreen',
          runtimeFiles: root,
          // Deliberately empty: nothing should need looking up, because the
          // runtime accounts for a plain coreutils binary's closure.
          searchPaths: const [],
        );

    expect(
      report.provided,
      contains('libc.so.6'),
      reason:
          'runtime $branch at ${root.path} did not account for libc — '
          '_indexRuntime is not finding libraries where this runtime puts them',
    );
    expect(
      report.staged,
      isEmpty,
      reason: 'vendored ${report.staged} from a runtime that provides it',
    );
    // Not asserted either way — see the note at the top — but it must be
    // well-formed when it does fire.
    for (final gap in report.symbolGaps) {
      expect(gap.staged, isNotEmpty);
      expect(gap.from, isNotEmpty);
      expect(gap.version, isNotEmpty);
    }
  });
}
