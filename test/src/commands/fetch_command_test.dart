import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:emb_cli/src/commands/fetch_command.dart';
import 'package:emb_cli/src/cross/process_runner.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:mocktail/mocktail.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

class _MockLogger extends Mock implements Logger {}

/// A real logger, so progress output works, that keeps what it was told.
class _CaptureLogger extends Logger {
  final errors = StringBuffer();
  final infos = StringBuffer();
  final warnings = StringBuffer();

  @override
  void warn(String? message, {String? tag, LogStyle? style}) =>
      warnings.writeln(message);

  @override
  void err(String? message, {LogStyle? style}) => errors.writeln(message);

  @override
  void info(String? message, {LogStyle? style}) => infos.writeln(message);
}

void main() {
  late Logger logger;
  late CommandRunner<int> runner;
  late Directory tmp;

  setUp(() {
    logger = _MockLogger();
    runner = CommandRunner<int>('emb', 'test')
      ..addCommand(FetchCommand(logger: logger));
    tmp = Directory.systemTemp.createTempSync('emb_fetch_');
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  test('no arguments prints usage and exits usage', () async {
    final code = await runner.run(['fetch']);
    expect(code, ExitCode.usage.code);
    verify(() => logger.err(any(that: contains('Usage: emb fetch')))).called(1);
  });

  test('a missing manifest exits usage', () async {
    final code = await runner.run(['fetch', p.join(tmp.path, 'nope.emb.yaml')]);
    expect(code, ExitCode.usage.code);
    verify(() => logger.err(any(that: contains('No emb manifest')))).called(1);
  });

  test('an unknown target on a real manifest exits usage', () async {
    final manifest = File(p.join(tmp.path, 'app.emb.yaml'))
      ..writeAsStringSync('''
cross:
  provider: arm-gnu
  image_url: https://example/os.img.xz
''');
    final code = await runner.run(['fetch', manifest.path, '-t', 'nope']);
    expect(code, ExitCode.usage.code);
    verify(
      () => logger.err(any(that: contains('Unknown target "nope"'))),
    ).called(1);
  });

  test('a native target needs no fetch and succeeds', () async {
    final manifest = File(p.join(tmp.path, 'app.emb.yaml'))
      ..writeAsStringSync('''
cross:
  provider: arm-gnu
  image_url: https://example/os.img.xz
''');
    final code = await runner.run(['fetch', manifest.path, '-t', 'local']);
    expect(code, ExitCode.success.code);
    verify(
      () => logger.info(any(that: contains('no toolchain/sysroot to fetch'))),
    ).called(1);
  });

  test('--app pointing at a dir without a pubspec exits usage', () async {
    final manifest = File(p.join(tmp.path, 'app.emb.yaml'))
      ..writeAsStringSync('''
cross:
  provider: arm-gnu
  image_url: https://example/os.img.xz
''');
    final noApp = Directory(p.join(tmp.path, 'notanapp'))..createSync();
    final code = await runner.run([
      'fetch',
      manifest.path,
      '-t',
      'local',
      '--app',
      noApp.path,
    ]);
    expect(code, ExitCode.usage.code);
    verify(() => logger.err(any(that: contains('no pubspec.yaml')))).called(1);
  });

  // An offline build reuses the embedder checkout and cannot make one, and a
  // target can extend one inside it (`source#<target>`), so fetch clones
  // cross.source: before the resolve when the resolve needs it.
  group('cross.source', () {
    late _CaptureLogger log;
    late Directory origin;

    Future<int?> fetch(List<String> args) {
      final r = CommandRunner<int>('emb', 'test')
        ..addCommand(FetchCommand(logger: log));
      return r.run(['fetch', ...args]);
    }

    /// A git repository holding an embedder project with one target, `rpi`.
    Future<void> makeOrigin({required String provider}) async {
      origin = Directory(p.join(tmp.path, 'origin', 'embedder'));
      Directory(p.join(origin.path, '.emb')).createSync(recursive: true);
      File(p.join(origin.path, '.emb', 'rpi.emb.yaml')).writeAsStringSync(
        'id: embedder\ncross:\n  targets:\n    rpi:\n'
        '      provider: $provider\n'
        '      image_url: https://example/os.img.xz\n',
      );
      for (final args in [
        ['init', '-q'],
        ['add', '-A'],
        ['commit', '-q', '-m', 'init'],
      ]) {
        final r = await Process.run('git', [
          '-c',
          'user.name=t',
          '-c',
          'user.email=t@example.invalid',
          '-c',
          'init.defaultBranch=main',
          ...args,
        ], workingDirectory: origin.path);
        expect(r.exitCode, 0, reason: '${r.stderr}');
      }
    }

    // [native] gives the shared block a provider, which the native build
    // needs and which would otherwise hide the cloned target's own.
    File manifest(String uri, {bool native = true}) =>
        File(p.join(tmp.path, 'app.emb.yaml'))..writeAsStringSync(
          'id: app\nworkspace: ws\ncross:\n'
          '${native ? '  provider: arm-gnu\n' : ''}'
          '  source: { uri: $uri }\n'
          '  targets:\n'
          "    pi: { extends: 'source#rpi' }\n"
          "    broken: { extends: 'nowhere#x' }\n",
        );

    /// The clone, in the workspace the manifest declares.
    File cloned() =>
        File(p.join(tmp.path, 'ws', 'app', 'embedder', '.emb', 'rpi.emb.yaml'));

    setUp(() => log = _CaptureLogger());

    // The cloned target names a provider emb does not have, which stops the
    // run right after the resolve with a value only the clone holds.
    test('is cloned first for a target that extends into it', () async {
      await makeOrigin(provider: 'only-in-the-clone');
      final f = manifest(origin.path, native: false);
      expect(await fetch([f.path, '-t', 'pi']), ExitCode.usage.code);
      expect(log.errors.toString(), contains('only-in-the-clone'));
      expect(cloned().existsSync(), isTrue);
    });

    test('is cloned for a target that does not need it to resolve', () async {
      await makeOrigin(provider: 'arm-gnu');
      final f = manifest(origin.path);
      expect(await fetch([f.path, '-t', 'local']), ExitCode.success.code);
      expect(cloned().existsSync(), isTrue);
    });

    test('a failed clone fails the fetch', () async {
      final f = manifest(p.join(tmp.path, 'no-such-repo'));
      expect(await fetch([f.path, '-t', 'pi']), ExitCode.software.code);
      expect(await fetch([f.path, '-t', 'local']), ExitCode.software.code);
    });

    test('a target that cannot resolve says why when selected', () async {
      await makeOrigin(provider: 'arm-gnu');
      final f = manifest(origin.path);
      expect(await fetch([f.path, '-t', 'broken']), ExitCode.usage.code);
      expect(log.errors.toString(), contains('no emb project'));
    });

    test('-w outranks the workspace the manifest declares', () async {
      await makeOrigin(provider: 'arm-gnu');
      final f = manifest(origin.path);
      final other = p.join(tmp.path, 'other');
      expect(
        await fetch([f.path, '-t', 'local', '--workspace', other]),
        ExitCode.success.code,
      );
      expect(cloned().existsSync(), isFalse);
      expect(Directory(p.join(other, 'app', 'embedder')).existsSync(), isTrue);
    });
  });

  // The app is the other checkout an offline build reuses and cannot make, so
  // fetch clones a declared cross.app and resolves its pub packages.
  group('cross.app', () {
    late _CaptureLogger log;
    late Directory origin;
    late List<({String exe, List<String> args, String? cwd})> calls;
    var onPath = false;

    Future<RunResult> fake(
      String exe,
      List<String> args, {
      String? workingDirectory,
      Map<String, String>? environment,
      bool includeParentEnvironment = true,
      bool runInShell = false,
      ProcessOutputMode output = ProcessOutputMode.capture,
      String? label,
    }) async {
      calls.add((exe: exe, args: args, cwd: workingDirectory));
      return const RunResult(0, '', '');
    }

    Future<int?> fetch(List<String> args) {
      final r = CommandRunner<int>('emb', 'test')
        ..addCommand(
          FetchCommand(
            logger: log,
            processRunner: fake,
            toolProbe: (tool) async => onPath,
          ),
        );
      return r.run(['fetch', ...args]);
    }

    /// A git repository holding a Flutter app at [sub] (the root when empty).
    Future<void> makeOrigin({bool lock = true, String sub = ''}) async {
      origin = Directory(p.join(tmp.path, 'origin', 'my_app'));
      final app = Directory(p.join(origin.path, sub))
        ..createSync(recursive: true);
      File(p.join(app.path, 'pubspec.yaml')).writeAsStringSync('name: a\n');
      if (lock) File(p.join(app.path, 'pubspec.lock')).writeAsStringSync('');
      for (final args in [
        ['init', '-q'],
        ['add', '-A'],
        ['commit', '-q', '-m', 'init'],
      ]) {
        final r = await Process.run('git', [
          '-c',
          'user.name=t',
          '-c',
          'user.email=t@example.invalid',
          '-c',
          'init.defaultBranch=main',
          ...args,
        ], workingDirectory: origin.path);
        expect(r.exitCode, 0, reason: '${r.stderr}');
      }
    }

    File manifest(String uri, {String extra = ''}) =>
        File(p.join(tmp.path, 'app.emb.yaml'))..writeAsStringSync(
          'id: app\nworkspace: ws\ncross:\n  provider: arm-gnu\n'
          '  app: { uri: $uri$extra }\n',
        );

    String clone() => p.join(tmp.path, 'ws', 'app', 'my_app');

    /// The SDK `emb flutter` would have put in the workspace.
    String workspaceSdk() {
      final bin = File(p.join(tmp.path, 'ws', 'flutter', 'bin', 'flutter'))
        ..createSync(recursive: true);
      return bin.path;
    }

    setUp(() {
      log = _CaptureLogger();
      calls = [];
      onPath = false;
    });

    test('is cloned and resolved with the workspace SDK', () async {
      await makeOrigin();
      final sdk = workspaceSdk();
      final f = manifest(origin.path);
      expect(await fetch([f.path, '-t', 'local']), ExitCode.success.code);
      expect(File(p.join(clone(), 'pubspec.yaml')).existsSync(), isTrue);
      expect(calls, hasLength(1));
      expect(calls.single.exe, sdk);
      expect(calls.single.args, ['pub', 'get', '--enforce-lockfile']);
      expect(calls.single.cwd, clone());
    });

    test('falls back to flutter on PATH', () async {
      await makeOrigin();
      onPath = true;
      final f = manifest(origin.path);
      expect(await fetch([f.path, '-t', 'local']), ExitCode.success.code);
      expect(calls.single.exe, 'flutter');
    });

    test('pubspec_path names the app inside the repo', () async {
      await makeOrigin(sub: 'packages/ui');
      workspaceSdk();
      final f = manifest(origin.path, extra: ', pubspec_path: packages/ui');
      expect(await fetch([f.path, '-t', 'local']), ExitCode.success.code);
      expect(calls.single.cwd, p.join(clone(), 'packages', 'ui'));
    });

    test('with no Flutter SDK it is cloned, and the gap is named', () async {
      await makeOrigin();
      final f = manifest(origin.path);
      expect(await fetch([f.path, '-t', 'local']), ExitCode.success.code);
      expect(Directory(clone()).existsSync(), isTrue);
      expect(calls, isEmpty);
      expect(log.warnings.toString(), contains('are not fetched'));
    });

    test('with no pubspec.lock it resolves unpinned and says so', () async {
      await makeOrigin(lock: false);
      workspaceSdk();
      final f = manifest(origin.path);
      expect(await fetch([f.path, '-t', 'local']), ExitCode.success.code);
      expect(calls.single.args, ['pub', 'get']);
      expect(log.warnings.toString(), contains('no pubspec.lock'));
    });

    test('--app replaces it: nothing is cloned', () async {
      await makeOrigin();
      onPath = true;
      final f = manifest(origin.path);
      expect(
        await fetch([f.path, '-t', 'local', '--app', origin.path]),
        ExitCode.success.code,
      );
      expect(Directory(clone()).existsSync(), isFalse);
      expect(calls.single.cwd, origin.path);
    });

    test('a failed clone fails the fetch', () async {
      final f = manifest(p.join(tmp.path, 'no-such-repo'));
      expect(await fetch([f.path, '-t', 'local']), ExitCode.software.code);
    });
  });
}
