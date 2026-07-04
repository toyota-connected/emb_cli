import 'dart:io';

import 'package:emb_cli/src/cross/cargo_vendor.dart';
import 'package:emb_cli/src/cross/process_runner.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('emb_vendor_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  Directory mkdir(String rel) =>
      Directory(p.join(tmp.path, rel))..createSync(recursive: true);
  void touch(String rel) => File(p.join(tmp.path, rel))
    ..createSync(recursive: true)
    ..writeAsStringSync('');

  group('cargoLockDir', () {
    test('finds a lock beside the module', () {
      final m = mkdir('crate');
      touch('crate/Cargo.lock');
      expect(cargoLockDir(m)!.path, m.path);
    });

    test('walks up to a workspace-root lock', () {
      final member = mkdir('ws/crates/foo');
      touch('ws/Cargo.lock');
      touch('ws/.git/HEAD'); // repo root marker
      expect(cargoLockDir(member)!.path, p.join(tmp.path, 'ws'));
    });

    test('stops at the .git boundary and reports unpinned', () {
      // Lock lives ABOVE the repo root — must not be picked up.
      final member = mkdir('repo/crate');
      touch('repo/.git/HEAD');
      touch('Cargo.lock'); // outside the repo
      expect(cargoLockDir(member), isNull);
    });

    test('returns null when there is no lock at all', () {
      expect(cargoLockDir(mkdir('nolock')), isNull);
    });
  });

  group('vendorConfig', () {
    test('rewrites the vendored-sources directory to absolute', () {
      const stdout = '''
[source.crates-io]
replace-with = "vendored-sources"

[source.vendored-sources]
directory = "vendor"
''';
      final out = vendorConfig(stdout, '/abs/store/vendor');
      expect(out, contains('directory = "/abs/store/vendor"'));
      expect(out, contains('replace-with = "vendored-sources"'));
      expect(out, isNot(contains('"vendor"\n')));
    });
  });

  group('vendor', () {
    test(
      'runs cargo vendor and writes an absolute CARGO_HOME config',
      () async {
        final crate = mkdir('crate');
        touch('crate/Cargo.lock');
        touch('crate/Cargo.toml');
        final store = mkdir('store');
        late List<String> gotArgs;
        String? gotCwd;
        Future<RunResult> fakeRun(
          String exe,
          List<String> args, {
          String? workingDirectory,
          Map<String, String>? environment,
          bool includeParentEnvironment = true,
          bool runInShell = false,
          ProcessOutputMode output = ProcessOutputMode.capture,
          String? label,
        }) async {
          gotArgs = [exe, ...args];
          gotCwd = workingDirectory;
          return const RunResult(
            0,
            '[source.vendored-sources]\ndirectory = "vendor"\n',
            '',
          );
        }

        final res = await CargoVendor(
          run: fakeRun,
        ).vendor(moduleSrc: crate, storeRoot: store);
        expect(res.ok, isTrue, reason: res.error);
        expect(gotArgs, containsAll(['cargo', 'vendor', '--locked']));
        expect(gotCwd, crate.path);
        final config = File(p.join(res.cargoHome!.path, 'config.toml'));
        expect(config.existsSync(), isTrue);
        expect(
          config.readAsStringSync(),
          contains(p.join(store.path, 'cargo-vendor')),
        );
      },
    );

    test('fails clearly when the module has no Cargo.lock', () async {
      final res = await CargoVendor(
        run: _unusedRun,
      ).vendor(moduleSrc: mkdir('nolock'), storeRoot: mkdir('store'));
      expect(res.ok, isFalse);
      expect(res.error, contains('no Cargo.lock'));
    });

    test(
      'locate finds a vendored home and ignores an un-vendored one',
      () async {
        final crate = mkdir('crate');
        touch('crate/Cargo.lock');
        touch('crate/Cargo.toml');
        final store = mkdir('store');
        final vendor = CargoVendor(
          run:
              (
                exe,
                args, {
                workingDirectory,
                environment,
                includeParentEnvironment = true,
                runInShell = false,
                output = ProcessOutputMode.capture,
                label,
              }) async {
                // Simulate cargo creating the vendor directory it was given.
                Directory(args.last).createSync(recursive: true);
                return const RunResult(0, 'directory = "vendor"\n', '');
              },
        );
        expect(vendor.locate(moduleSrc: crate, storeRoot: store), isNull);
        final res = await vendor.vendor(moduleSrc: crate, storeRoot: store);
        expect(
          vendor.locate(moduleSrc: crate, storeRoot: store)!.path,
          res.cargoHome!.path,
        );
      },
    );
  });
}

Future<RunResult> _unusedRun(
  String exe,
  List<String> args, {
  String? workingDirectory,
  Map<String, String>? environment,
  bool includeParentEnvironment = true,
  bool runInShell = false,
  ProcessOutputMode output = ProcessOutputMode.capture,
  String? label,
}) async => throw StateError('cargo should not run');
