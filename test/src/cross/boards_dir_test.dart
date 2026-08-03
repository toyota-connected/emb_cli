import 'package:emb_cli/src/cross/boards_dir.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('resolveBoardsDir', () {
    test('EMB_BOARDS_DIR wins over everything', () {
      final d = resolveBoardsDir(
        environment: const {
          'EMB_BOARDS_DIR': '/custom/boards',
          'XDG_DATA_HOME': '/xdg',
          'HOME': '/home/u',
        },
        operatingSystem: 'linux',
      );
      expect(d.path, '/custom/boards');
    });

    test('an empty override is ignored, not treated as a path', () {
      final d = resolveBoardsDir(
        environment: const {'EMB_BOARDS_DIR': '', 'HOME': '/home/u'},
        operatingSystem: 'linux',
      );
      expect(d.path, p.join('/home/u', '.local', 'share', 'emb', 'boards'));
    });

    test('lands under the data home, never the cache home', () {
      // `emb cache gc` must never be able to delete the board library.
      final d = resolveBoardsDir(
        environment: const {'HOME': '/home/u', 'XDG_CACHE_HOME': '/c'},
        operatingSystem: 'linux',
      );
      expect(d.path, isNot(contains('/c')));
      expect(d.path, contains(p.join('.local', 'share')));
    });
  });

  group('dataHomeDir per OS', () {
    test('Linux honors XDG_DATA_HOME', () {
      expect(
        dataHomeDir(
          environment: const {'XDG_DATA_HOME': '/xdg/data', 'HOME': '/home/u'},
          operatingSystem: 'linux',
        ).path,
        '/xdg/data',
      );
    });

    test('Linux falls back to ~/.local/share', () {
      expect(
        dataHomeDir(
          environment: const {'HOME': '/home/u'},
          operatingSystem: 'linux',
        ).path,
        p.join('/home/u', '.local', 'share'),
      );
    });

    test('macOS uses Application Support and ignores XDG', () {
      expect(
        dataHomeDir(
          environment: const {'HOME': '/Users/u', 'XDG_DATA_HOME': '/xdg'},
          operatingSystem: 'macos',
        ).path,
        p.join('/Users/u', 'Library', 'Application Support'),
      );
    });

    test('Windows uses LOCALAPPDATA', () {
      expect(
        dataHomeDir(
          environment: const {'LOCALAPPDATA': r'C:\Users\u\AppData\Local'},
          operatingSystem: 'windows',
        ).path,
        r'C:\Users\u\AppData\Local',
      );
    });

    test(r'Windows falls back to USERPROFILE\AppData\Local', () {
      expect(
        dataHomeDir(
          environment: const {'USERPROFILE': r'C:\Users\u'},
          operatingSystem: 'windows',
        ).path,
        p.join(r'C:\Users\u', 'AppData', 'Local'),
      );
    });
  });
}
