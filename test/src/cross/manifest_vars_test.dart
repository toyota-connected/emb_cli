import 'package:emb_cli/src/cross/manifest_vars.dart';
import 'package:test/test.dart';

void main() {
  group('expandManifestVars', () {
    test('expands a known variable', () {
      expect(
        expandManifestVars('\${embedder_root}/lib', {'embedder_root': '/a/b'}),
        '/a/b/lib',
      );
    });

    test('expands multiple variables in one string', () {
      expect(
        expandManifestVars(
          '\${embedder_root}/\${runnable}',
          {'embedder_root': '/emb', 'runnable': '/out/runnable'},
        ),
        '/emb//out/runnable',
      );
    });

    test('leaves unknown tokens verbatim', () {
      expect(
        expandManifestVars('\${unknown}/lib', {'embedder_root': '/a'}),
        '\${unknown}/lib',
      );
    });

    test('expands app_root when present', () {
      expect(
        expandManifestVars(
          '\${app_root}/assets',
          {'app_root': '/myapp'},
        ),
        '/myapp/assets',
      );
    });

    test('no-ops on a plain path', () {
      expect(
        expandManifestVars('/usr/lib/libfoo.so', {'runnable': '/out/runnable'}),
        '/usr/lib/libfoo.so',
      );
    });

    test('expands runnable with multi-backend suffix', () {
      const runnableDir = '/build/root/runnable-wayland';
      expect(
        expandManifestVars('\${runnable}/lib/libfoo.so', {
          'runnable': runnableDir,
        }),
        '/build/root/runnable-wayland/lib/libfoo.so',
      );
    });
  });
}
