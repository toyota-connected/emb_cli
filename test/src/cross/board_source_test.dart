import 'dart:io';

import 'package:emb_cli/src/cross/board_source.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('emb_bsrc_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  group('BoardSourceConfig', () {
    test('defaults to the public source when no file exists', () {
      final config = BoardSourceConfig.load(
        File('${tmp.path}/nonexistent.yaml'),
      );
      expect(config.sources, hasLength(1));
      expect(config.sources.first.name, 'emb-public');
      expect(config.sources.first, isA<GithubBoardSource>());
    });

    test('round-trips through save and load', () {
      final file = File('${tmp.path}/boards.yaml');
      BoardSourceConfig([
        const GithubBoardSource(
          name: 'public',
          repo: 'org/repo',
          tokenEnv: 'MY_TOKEN',
        ),
        const LocalBoardSource(name: 'local', path: '/opt/boards'),
      ]).save(file);

      final loaded = BoardSourceConfig.load(file);
      expect(loaded.sources, hasLength(2));

      final gh = loaded.sources[0] as GithubBoardSource;
      expect(gh.name, 'public');
      expect(gh.repo, 'org/repo');
      expect(gh.path, 'boards');
      expect(gh.ref, 'main');
      expect(gh.tokenEnv, 'MY_TOKEN');

      final loc = loaded.sources[1] as LocalBoardSource;
      expect(loc.name, 'local');
      expect(loc.path, '/opt/boards');
    });

    test('round-trips ssh transport through save and load', () {
      final file = File('${tmp.path}/boards.yaml');
      BoardSourceConfig([
        const GithubBoardSource(
          name: 'private',
          repo: 'org/private-repo',
          transport: 'ssh',
        ),
      ]).save(file);

      final loaded = BoardSourceConfig.load(file);
      final gh = loaded.sources[0] as GithubBoardSource;
      expect(gh.transport, 'ssh');
      expect(gh.useSsh, isTrue);
    });

    test('contains and operator[] find sources by name', () {
      final config = BoardSourceConfig([
        const GithubBoardSource(name: 'a', repo: 'x/y'),
        const LocalBoardSource(name: 'b', path: '/z'),
      ]);
      expect(config.contains('a'), isTrue);
      expect(config.contains('c'), isFalse);
      expect(config['b']?.name, 'b');
      expect(config['missing'], isNull);
    });

    test('malformed YAML falls back to default', () {
      final file = File('${tmp.path}/bad.yaml')
        ..writeAsStringSync('not: a: valid: yaml: [');
      final config = BoardSourceConfig.load(file);
      expect(config.sources.first.name, 'emb-public');
    });
  });

  group('BoardSource.fromMap', () {
    test('parses a github source', () {
      final s = BoardSource.fromMap({
        'name': 'test',
        'type': 'github',
        'repo': 'org/repo',
      });
      expect(s, isA<GithubBoardSource>());
      expect((s as GithubBoardSource).repo, 'org/repo');
    });

    test('parses a local source', () {
      final s = BoardSource.fromMap({
        'name': 'loc',
        'type': 'local',
        'path': '/foo',
      });
      expect(s, isA<LocalBoardSource>());
      expect((s as LocalBoardSource).path, '/foo');
    });

    test('throws on unknown type', () {
      expect(
        () => BoardSource.fromMap({'type': 'ftp', 'name': 'x'}),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('throws on path-traversal name', () {
      expect(
        () => BoardSource.fromMap({
          'type': 'github',
          'name': '../escape',
          'repo': 'org/repo',
        }),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('throws on empty name', () {
      expect(
        () => BoardSource.fromMap({
          'type': 'github',
          'name': '',
          'repo': 'org/repo',
        }),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('throws on path-traversal repo', () {
      expect(
        () => BoardSource.fromMap({
          'type': 'github',
          'name': 'test',
          'repo': '../escape',
        }),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('throws on empty repo', () {
      expect(
        () =>
            BoardSource.fromMap({'type': 'github', 'name': 'test', 'repo': ''}),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('throws on path-traversal path', () {
      expect(
        () => BoardSource.fromMap({
          'type': 'github',
          'name': 'test',
          'repo': 'org/repo',
          'path': '../.git',
        }),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('throws on absolute path', () {
      expect(
        () => BoardSource.fromMap({
          'type': 'github',
          'name': 'test',
          'repo': 'org/repo',
          'path': '/etc/passwd',
        }),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('throws on invalid transport', () {
      expect(
        () => BoardSource.fromMap({
          'type': 'github',
          'name': 'test',
          'repo': 'org/repo',
          'transport': 'ftp',
        }),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('BoardSourceConfig.load warnings', () {
    test('calls onWarning when config has invalid source names', () {
      final file = File('${tmp.path}/bad-name.yaml')
        ..writeAsStringSync('''
sources:
  - name: "../escape"
    type: github
    repo: org/repo
''');
      final warnings = <String>[];
      final config = BoardSourceConfig.load(file, onWarning: warnings.add);
      expect(config.sources.first.name, 'emb-public');
      expect(warnings, hasLength(1));
      expect(warnings.first, contains('bad-name.yaml'));
    });

    test('skips bad entry but keeps valid siblings', () {
      final file = File('${tmp.path}/mixed.yaml')
        ..writeAsStringSync('''
sources:
  - name: "../escape"
    type: github
    repo: org/repo
  - name: good
    type: local
    path: /opt/boards
''');
      final warnings = <String>[];
      final config = BoardSourceConfig.load(file, onWarning: warnings.add);
      expect(config.sources, hasLength(1));
      expect(config.sources.first.name, 'good');
      expect(config.droppedEntries, isTrue);
      expect(warnings, hasLength(1));
      expect(warnings.first, contains('Skipping'));
    });

    test('calls onWarning on malformed YAML', () {
      final file = File('${tmp.path}/bad.yaml')
        ..writeAsStringSync('not: a: valid: yaml: [');
      final warnings = <String>[];
      BoardSourceConfig.load(file, onWarning: warnings.add);
      expect(warnings, hasLength(1));
    });
  });

  group('the default source points where the boards actually are', () {
    /// The repo root, found by walking up from the test file to the directory
    /// holding `pubspec.yaml`. Tests run from the package root today, but a
    /// relative `boards/` would break silently if that ever changed.
    Directory repoRoot() {
      var dir = Directory.current;
      while (!File(p.join(dir.path, 'pubspec.yaml')).existsSync()) {
        final up = dir.parent;
        if (up.path == dir.path) {
          fail('could not find the repo root from ${Directory.current.path}');
        }
        dir = up;
      }
      return dir;
    }

    test("defaultSourcePath holds this checkout's board files", () {
      // The guard #261 needed. 0.4.0 moved the boards to boards/emb-public/ and
      // left the default at boards/, so every `emb boards sync` from a pub.dev
      // install found a directory with no *.emb.yaml in it and failed. The
      // sync test could not catch it: its fake GitHub served whatever path the
      // default asked for. Only the real layout can.
      final dir = Directory(p.join(repoRoot().path, defaultSourcePath));
      expect(
        dir.existsSync(),
        isTrue,
        reason: '$defaultSourcePath does not exist in this checkout',
      );
      final boards = dir
          .listSync()
          .whereType<File>()
          .map((f) => p.basename(f.path))
          .where((n) => n.endsWith('.emb.yaml'))
          .toList();
      expect(
        boards,
        isNotEmpty,
        reason:
            'a boards sync lists $defaultSourcePath and keeps only *.emb.yaml; '
            'with none there it reports finding no boards. Move the constant, '
            'not just the files.',
      );
    });

    test('the stale path is no longer where the boards are', () {
      // Guards the inverse: if the files move back, the repair below would
      // quietly rewrite a correct path into a broken one.
      final dir = Directory(p.join(repoRoot().path, staleDefaultPath));
      final loose = dir.existsSync()
          ? dir
                .listSync()
                .whereType<File>()
                .where((f) => f.path.endsWith('.emb.yaml'))
                .toList()
          : <File>[];
      expect(
        loose,
        isEmpty,
        reason:
            'board files are back in $staleDefaultPath, so repairDefaultPath '
            'now rewrites a working path into a broken one',
      );
    });

    test(
      'defaultSource carries that path, not the GithubBoardSource default',
      () {
        expect(defaultSource.path, defaultSourcePath);
      },
    );
  });

  group('repairDefaultPath', () {
    GithubBoardSource gh({
      String name = 'emb-public',
      String repo = 'toyota-connected/emb_cli',
      String path = staleDefaultPath,
    }) => GithubBoardSource(name: name, repo: repo, path: path, ref: 'auto');

    test('corrects a persisted stale default', () {
      // toMap always writes path, so anyone who ran `emb boards add` has the
      // pre-0.4.0 default on disk. Fixing only the constant leaves them broken.
      final fixed = repairDefaultPath(gh());
      expect((fixed as GithubBoardSource).path, defaultSourcePath);
      expect(fixed.ref, 'auto', reason: 'the rest of the source is preserved');
    });

    test('preserves token_env and transport while correcting the path', () {
      final fixed = repairDefaultPath(
        const GithubBoardSource(
          name: 'emb-public',
          repo: 'toyota-connected/emb_cli',
          // Spelled out though it equals GithubBoardSource's own default --
          // relying on that default is how #261 happened.
          // ignore: avoid_redundant_argument_values
          path: staleDefaultPath,
          ref: 'auto',
          tokenEnv: 'GH_PAT',
          transport: 'ssh',
        ),
      );
      expect((fixed as GithubBoardSource).path, defaultSourcePath);
      expect(fixed.tokenEnv, 'GH_PAT');
      expect(fixed.transport, 'ssh');
    });

    test('leaves another name, repo, or path alone', () {
      // Only the shipped default's full identity is repaired; a user who aimed
      // their own source at boards/ chose that.
      for (final source in [
        gh(name: 'mine'),
        gh(repo: 'someone/else'),
        gh(path: 'board-files'),
      ]) {
        expect(
          identical(repairDefaultPath(source), source),
          isTrue,
          reason: 'repaired a source it should not touch: ${source.toMap()}',
        );
      }
    });

    test('leaves a local source alone', () {
      const local = LocalBoardSource(
        name: 'emb-public',
        path: staleDefaultPath,
      );
      expect(identical(repairDefaultPath(local), local), isTrue);
    });

    test('load repairs a stale default and flags it, without warning', () {
      // Silent: this load runs on every `emb cross`, and the stale value is one
      // emb wrote itself. The flag is how `boards sync` knows to persist it.
      final file = File(p.join(tmp.path, 'boards.yaml'))
        ..writeAsStringSync('''
sources:
  - name: emb-public
    type: github
    repo: toyota-connected/emb_cli
    path: $staleDefaultPath
    ref: auto
''');
      final warnings = <String>[];
      final config = BoardSourceConfig.load(file, onWarning: warnings.add);
      expect(warnings, isEmpty);
      expect(config.repairedDefaultPath, isTrue);
      expect(
        (config.sources.single as GithubBoardSource).path,
        defaultSourcePath,
      );
    });

    test('load does not flag a config already carrying the right path', () {
      final file = File(p.join(tmp.path, 'boards.yaml'))
        ..writeAsStringSync('''
sources:
  - name: emb-public
    type: github
    repo: toyota-connected/emb_cli
    path: $defaultSourcePath
    ref: auto
''');
      final config = BoardSourceConfig.load(file);
      expect(config.repairedDefaultPath, isFalse);
    });
  });
}
