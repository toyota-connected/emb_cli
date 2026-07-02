import 'package:emb_cli/src/cache/cache_dir.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test('EMB_CACHE_DIR wins', () {
    expect(
      resolveCacheDir(environment: {'EMB_CACHE_DIR': '/a/b'}).path,
      '/a/b',
    );
  });

  test('falls back to XDG_CACHE_HOME/emb', () {
    expect(
      resolveCacheDir(environment: {'XDG_CACHE_HOME': '/x'}).path,
      p.join('/x', 'emb'),
    );
  });

  test('falls back to ~/.cache/emb', () {
    expect(
      resolveCacheDir(environment: {'HOME': '/home/u'}).path,
      p.join('/home/u', '.cache', 'emb'),
    );
  });
}
