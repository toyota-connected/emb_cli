import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:emb_cli/src/cache/cas.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('emb_cas_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  /// A loopback server that serves [body] and counts requests.
  Future<(String url, int Function() hits, HttpServer server)> serve(
    List<int> body,
  ) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var n = 0;
    server.listen((req) {
      n++;
      req.response
        ..add(body)
        ..close();
    });
    return ('http://127.0.0.1:${server.port}/blob', () => n, server);
  }

  test('downloads, content-addresses, then serves from cache', () async {
    final body = utf8.encode('hello cas');
    final (url, hits, server) = await serve(body);
    addTearDown(() => server.close(force: true));

    final cas = Cas(tmp);
    addTearDown(cas.close);

    final f1 = await cas.ensure(url);
    expect(f1.readAsBytesSync(), body);
    final sha = sha256.convert(body).toString();
    expect(p.basename(f1.parent.path), sha); // keyed by content hash
    expect(hits(), 1);

    // A second ensure with the known sha is a cache hit — no re-download.
    final f2 = await cas.ensure(url, expectedSha: sha);
    expect(f2.path, f1.path);
    expect(hits(), 1);
  });

  test('rejects a sha mismatch', () async {
    final (url, _, server) = await serve(utf8.encode('x'));
    addTearDown(() => server.close(force: true));
    final cas = Cas(tmp);
    addTearDown(cas.close);
    await expectLater(
      cas.ensure(url, expectedSha: 'da39a3ee5e6b4b0d3255bfef95601890'),
      throwsA(isA<CasException>()),
    );
  });

  test('a non-200 response throws', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) {
      req.response
        ..statusCode = 404
        ..close();
    });
    addTearDown(() => server.close(force: true));
    final cas = Cas(tmp);
    addTearDown(cas.close);
    await expectLater(
      cas.ensure('http://127.0.0.1:${server.port}/missing'),
      throwsA(isA<CasException>()),
    );
  });
}
