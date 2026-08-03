import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:emb_cli/src/commands/boards_command.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:mocktail/mocktail.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

class _MockLogger extends Mock implements Logger {}

class _MockProgress extends Mock implements Progress {}

/// A stand-in for the GitHub contents API.
///
/// A real loopback server rather than a mocked `HttpClient`: the fetch path is
/// `dart:io` end to end, and faking that interface would mostly assert that the
/// mock was wired correctly. This exercises the request, the JSON shape, and
/// the file writes for real.
class _FakeGitHub {
  _FakeGitHub(this._server, {required this.boards}) {
    _server.listen((req) async {
      requestedPaths.add('${req.uri.path}?${req.uri.query}');
      if (req.uri.path.endsWith('/contents/boards')) {
        if (failListing) {
          req.response.statusCode = HttpStatus.notFound;
          await req.response.close();
          return;
        }
        final body = [
          for (final name in boards.keys)
            {'type': 'file', 'name': name, 'download_url': '$origin/raw/$name'},
          // A non-board entry the client must ignore.
          {'type': 'file', 'name': 'README.md', 'download_url': '$origin/x'},
          {'type': 'dir', 'name': 'nested', 'download_url': null},
        ];
        req.response
          ..headers.contentType = ContentType.json
          ..write(jsonEncode(body));
        await req.response.close();
        return;
      }
      final name = p.basename(req.uri.path);
      final content = boards[name];
      if (content == null) {
        req.response.statusCode = HttpStatus.notFound;
      } else {
        req.response.write(content);
      }
      await req.response.close();
    });
  }

  static Future<_FakeGitHub> start(Map<String, String> boards) async =>
      _FakeGitHub(
        await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
        boards: boards,
      );

  final HttpServer _server;
  final Map<String, String> boards;
  final List<String> requestedPaths = [];
  bool failListing = false;

  String get origin => 'http://127.0.0.1:${_server.port}';
  Uri get base => Uri.parse(origin);
  Future<void> close() => _server.close(force: true);
}

void main() {
  late Logger logger;
  late Directory tmp;
  late _FakeGitHub github;
  final info = <String>[];

  setUp(() async {
    logger = _MockLogger();
    info.clear();
    when(() => logger.progress(any())).thenReturn(_MockProgress());
    when(() => logger.info(any())).thenAnswer((i) {
      info.add('${i.positionalArguments.first}');
    });
    when(() => logger.err(any())).thenAnswer((i) {
      info.add('${i.positionalArguments.first}');
    });
    tmp = Directory.systemTemp.createTempSync('emb_sync_');
    github = await _FakeGitHub.start({
      'raspberry-pi.emb.yaml': 'id: raspberry-pi\ntype: board\n',
    });
  });

  tearDown(() async {
    await github.close();
    tmp.deleteSync(recursive: true);
  });

  Future<int> runSync(List<String> args) async {
    final runner = CommandRunner<int>('emb', 'test')
      ..addCommand(
        BoardsCommand(
          logger: logger,
          apiBase: github.base,
          environment: {
            'HOME': tmp.path,
            'XDG_DATA_HOME': p.join(tmp.path, 'data'),
          },
        ),
      );
    return await runner.run(['boards', 'sync', ...args]) ?? 0;
  }

  Directory dest() => Directory(p.join(tmp.path, 'data', 'emb', 'boards'));

  test('downloads the board files and writes the version stamp', () async {
    final code = await runSync([]);
    expect(code, ExitCode.success.code);
    expect(
      File(p.join(dest().path, 'raspberry-pi.emb.yaml')).readAsStringSync(),
      contains('id: raspberry-pi'),
    );
    expect(
      File(p.join(dest().path, '.emb-boards-version')).existsSync(),
      isTrue,
      reason: 'the stamp is how version skew is detectable later',
    );
  });

  test('ignores entries that are not board files', () async {
    await runSync([]);
    final written = dest().listSync().map((e) => p.basename(e.path)).toList();
    expect(written, contains('raspberry-pi.emb.yaml'));
    expect(written, isNot(contains('README.md')));
    expect(written, isNot(contains('nested')));
  });

  test('defaults to the tag matching this emb, and --ref overrides', () async {
    await runSync([]);
    expect(github.requestedPaths.first, contains('ref=v'));

    github.requestedPaths.clear();
    await runSync(['--ref', 'main']);
    expect(github.requestedPaths.first, contains('ref=main'));
  });

  test('a failed listing reports it and writes nothing', () async {
    github.failListing = true;
    final code = await runSync([]);
    expect(code, isNot(ExitCode.success.code));
    expect(dest().existsSync(), isFalse, reason: 'no partial install');
    expect(
      info.join('\n'),
      contains('--ref'),
      reason: 'an emb newer than the published tag needs to be told what to do',
    );
  });
}
