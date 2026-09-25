import 'dart:io';

import 'package:emb_cli/src/cross/board_source.dart';
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
      final original = BoardSourceConfig([
        const GithubBoardSource(
          name: 'public',
          repo: 'org/repo',
          path: 'boards',
          ref: 'main',
          tokenEnv: 'MY_TOKEN',
        ),
        const LocalBoardSource(name: 'local', path: '/opt/boards'),
      ]);
      original.save(file);

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
      final original = BoardSourceConfig([
        const GithubBoardSource(
          name: 'private',
          repo: 'org/private-repo',
          transport: 'ssh',
        ),
      ]);
      original.save(file);

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
        () => BoardSource.fromMap({
          'type': 'github',
          'name': 'test',
          'repo': '',
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
      final config = BoardSourceConfig.load(
        file,
        onWarning: warnings.add,
      );
      expect(config.sources.first.name, 'emb-public');
      expect(warnings, hasLength(1));
      expect(warnings.first, contains('bad-name.yaml'));
    });

    test('calls onWarning on malformed YAML', () {
      final file = File('${tmp.path}/bad.yaml')
        ..writeAsStringSync('not: a: valid: yaml: [');
      final warnings = <String>[];
      BoardSourceConfig.load(file, onWarning: warnings.add);
      expect(warnings, hasLength(1));
    });
  });
}
