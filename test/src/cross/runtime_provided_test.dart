import 'dart:io';

import 'package:emb_cli/src/cross/runtime_provided.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  late String sdk;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('emb_rtprov_');
    sdk = p.join(tmp.path, 'sdk');
    Directory(sdk).createSync();
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  void elf(String name) => File(
    p.join(sdk, name),
  ).writeAsBytesSync([0x7f, 0x45, 0x4c, 0x46, 2, 1, 1]);
  void link(String name, String to) => Link(p.join(sdk, name)).createSync(to);

  List<String> missing(List<String> names, Set<String> runtime) =>
      libsMissingFromRuntime(names, [sdk], runtime);

  test('follows a development link to the soname the runtime ships', () {
    // -lSDL2 links libSDL2.so, which is libSDL2-2.0.so.0 underneath.
    elf('libSDL2-2.0.so.0.3200.70');
    link('libSDL2-2.0.so.0', 'libSDL2-2.0.so.0.3200.70');
    link('libSDL2.so', 'libSDL2-2.0.so.0');
    expect(missing(['SDL2'], {'libSDL2-2.0.so.0'}), isEmpty);
    expect(missing(['SDL2'], {'libSDL2-2.0.so.0.3200.70'}), isEmpty);
    expect(missing(['SDL2'], {'libother.so.1'}), ['libSDL2.so']);
  });

  test('takes an unversioned shared object as itself', () {
    // NSS ships libnss3.so with no version suffix, in SDK and runtime alike.
    elf('libnss3.so');
    expect(missing(['nss3'], {'libnss3.so'}), isEmpty);
    expect(missing(['nss3'], const {}), ['libnss3.so']);
  });

  test('needs every shared object a linker script names', () {
    File(p.join(sdk, 'libm.so')).writeAsStringSync(
      '/* GNU ld script */\n'
      'GROUP ( /usr/lib/x86_64-linux-gnu/libm.so.6 '
      'AS_NEEDED ( /usr/lib/x86_64-linux-gnu/libmvec.so.1 ) )\n',
    );
    expect(missing(['m'], {'libm.so.6', 'libmvec.so.1'}), isEmpty);
    expect(missing(['m'], {'libm.so.6'}), ['libm.so']);
  });

  test('judges an absolute link by its target name', () {
    // Resolving it would land on the host, not in the SDK.
    link('libbar.so', '/usr/lib/libbar.so.1');
    expect(missing(['bar'], {'libbar.so.1'}), isEmpty);
    expect(missing(['bar'], const {}), ['libbar.so']);
  });

  test('never calls a static-only or absent library missing', () {
    File(p.join(sdk, 'libfoo.a')).writeAsStringSync('!<arch>\n');
    expect(missing(['foo', 'nowhere'], const {}), isEmpty);
  });

  test('reports each name once, sorted', () {
    elf('libz.so');
    elf('liba.so');
    expect(missing(['z', 'a', 'z'], const {}), ['liba.so', 'libz.so']);
  });
}
