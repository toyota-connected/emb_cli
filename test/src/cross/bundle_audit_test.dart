import 'dart:io';
import 'dart:typed_data';

import 'package:emb_cli/src/cross/bundle_audit.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// A minimal little-endian ELF header for the given machine (default aarch64).
Uint8List _elf({int eMachine = 0xB7}) {
  final b = Uint8List(64);
  b[0] = 0x7f;
  b[1] = 0x45;
  b[2] = 0x4c;
  b[3] = 0x46;
  b[4] = 2; // 64-bit
  b[5] = 1; // little-endian
  ByteData.sublistView(b).setUint16(18, eMachine, Endian.little);
  return b;
}

void main() {
  late Directory tmp;
  late Directory lib;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('emb_audit_');
    lib = Directory(p.join(tmp.path, 'lib'))..createSync();
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  void put(String name, {int eMachine = 0xB7}) =>
      File(p.join(lib.path, name)).writeAsBytesSync(_elf(eMachine: eMachine));

  const triple = 'aarch64-none-linux-gnu';

  test('a clean bundle with only engine and app image audits ok', () {
    put('libapp.so');
    put('libflutter_engine.so');
    final a = auditBundleLib(lib, triple: triple, moduleArtifacts: const []);
    expect(a.ok, isTrue);
  });

  test('a declared module artifact and its version aliases are allowed', () {
    put('libfoo.so.1.2.3');
    Link(p.join(lib.path, 'libfoo.so.1')).createSync('libfoo.so.1.2.3');
    Link(p.join(lib.path, 'libfoo.so')).createSync('libfoo.so.1');
    final a = auditBundleLib(
      lib,
      triple: triple,
      moduleArtifacts: const ['libfoo.so'],
    );
    expect(a.ok, isTrue, reason: a.strays.toString());
  });

  test('an undeclared stray library is flagged', () {
    put('libapp.so');
    put('libstdc++.so.6');
    final a = auditBundleLib(lib, triple: triple, moduleArtifacts: const []);
    expect(a.strays, ['libstdc++.so.6']);
    expect(a.ok, isFalse);
  });

  test('a host-arch engine or app image is flagged', () {
    put('libapp.so', eMachine: 0x3E); // x86_64 build slipped in
    put('libflutter_engine.so');
    final a = auditBundleLib(lib, triple: triple, moduleArtifacts: const []);
    expect(a.archMismatches, hasLength(1));
    expect(a.archMismatches.single, startsWith('libapp.so:'));
    expect(a.ok, isFalse);
  });

  test('a missing lib/ directory audits clean', () {
    final a = auditBundleLib(
      Directory(p.join(tmp.path, 'nope')),
      triple: triple,
      moduleArtifacts: const [],
    );
    expect(a.ok, isTrue);
  });
}
