import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:emb_cli/src/commands/init_command.dart';
import 'package:emb_cli/src/cross/cross_project.dart';
import 'package:emb_cli/src/cross/cross_target.dart';
import 'package:emb_cli/src/init/flatpak_repo_template.dart';
import 'package:emb_cli/src/manifest/manifest_loader.dart';
import 'package:emb_cli/src/version.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:mocktail/mocktail.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

class _MockLogger extends Mock implements Logger {}

const _embedderHead = '9eeee8925ef34838418156da21bcec7872db6c9b';
const _appHead = 'd12640d4b08ee6e706fd8c64a83fba0620c9aa8d';
const _appUri = 'https://example.com/me/my_app.git';

/// `emb init flatpak` wired to fake `git` and `flatpak`, writing under a temp
/// directory.
class _Harness {
  _Harness({
    this.gitFails = false,
    this.gitMissing = false,
    this.flatpak = const {},
    bool boards = true,
  }) {
    tmp = Directory.systemTemp.createTempSync('emb-init-cmd-');
    addTearDown(() => tmp.deleteSync(recursive: true));
    resolver = boards
        ? CrossProjectResolver()
        // An empty directory: a compiled emb before `emb boards sync`.
        : CrossProjectResolver(
            const ManifestLoader(),
            Directory(p.join(tmp.path, 'no-boards'))..createSync(),
            const {},
          );
    out = Directory(p.join(tmp.path, 'repo'));
    when(() => logger.info(any())).thenAnswer((i) {
      infos.add(i.positionalArguments.single as String? ?? '');
    });
    when(() => logger.warn(any())).thenAnswer((i) {
      warnings.add(i.positionalArguments.single as String? ?? '');
    });
    when(() => logger.err(any())).thenAnswer((i) {
      errors.add(i.positionalArguments.single as String? ?? '');
    });
  }

  final bool gitFails;
  final bool gitMissing;

  /// `flatpak remote-ls` stdout per scope (`--user` / `--system`); a scope
  /// not listed exits non-zero.
  final Map<String, String> flatpak;
  late final CrossProjectResolver resolver;
  late final Directory tmp;
  late final Directory out;

  final logger = _MockLogger();
  final infos = <String>[];
  final warnings = <String>[];
  final errors = <String>[];

  /// Every process the command started: `[executable, ...args]`.
  final calls = <List<String>>[];

  Future<ProcessResult> _run(String exe, List<String> args) async {
    calls.add([exe, ...args]);
    if (exe == 'git') {
      if (gitMissing) throw ProcessException(exe, args, 'not found', 2);
      if (gitFails) return ProcessResult(0, 128, '', 'fatal: no such repo\n');
      final uri = args[args.length - 2];
      final isApp = uri == _appUri;
      return ProcessResult(
        0,
        0,
        'ref: refs/heads/${isApp ? 'main' : 'v3.0'}\tHEAD\n'
            '${isApp ? _appHead : _embedderHead}\tHEAD\n',
        '',
      );
    }
    final scope = args[1];
    final listing = flatpak[scope];
    return listing == null
        ? ProcessResult(0, 1, '', 'error: no remote')
        : ProcessResult(0, 0, listing, '');
  }

  /// Runs `emb init flatpak <out> --app-id com.example.MyApp` plus [extra].
  Future<int?> run([
    List<String> extra = const [],
    String appId = 'com.example.MyApp',
  ]) {
    final command = InitCommand(
      logger: logger,
      processRunner: _run,
      resolver: resolver,
    );
    return (CommandRunner<int>('emb', 'test')..addCommand(command)).run([
      'init',
      'flatpak',
      out.path,
      '--app-id',
      appId,
      ...extra,
    ]);
  }

  List<List<String>> callsTo(String exe) => [
    for (final c in calls)
      if (c.first == exe) c,
  ];

  File file(String rel) => File(p.join(out.path, rel));

  String read(String rel) => file(rel).readAsStringSync();

  YamlMap manifest([String name = 'my-app.emb.yaml']) =>
      loadYaml(read(name)) as YamlMap;

  YamlMap cross([String name = 'my-app.emb.yaml']) =>
      manifest(name)['cross'] as YamlMap;

  /// Files under [out], relative.
  Set<String> get written => out.existsSync()
      ? {
          for (final f in out.listSync(recursive: true))
            if (f is File) p.relative(f.path, from: out.path),
        }
      : {};
}

void main() {
  group('emb init', () {
    test('flatpak is the one format, as a subcommand', () {
      final init = InitCommand(logger: _MockLogger());
      expect(init.subcommands.keys, ['flatpak']);
    });
  });

  group('emb init flatpak', () {
    test('writes the repo and reports the build command', () async {
      final h = _Harness();
      expect(await h.run(['--app', _appUri]), ExitCode.success.code);
      expect(h.written, {
        'my-app.emb.yaml',
        'README.md',
        '.gitignore',
        'metainfo.xml',
        'icon.png',
        '.github/workflows/flatpak.yml',
      });
      expect(h.file('icon.png').readAsBytesSync(), flatpakPlaceholderIcon);
      expect(
        h.infos,
        contains(
          '  emb cross my-app.emb.yaml --target local --build --flatpak',
        ),
      );
      expect(h.errors, isEmpty);
    });

    // The generator's own bar: what it leaves behind loads the way
    // `emb cross` would load it.
    test('what it writes resolves as a cross project', () async {
      final h = _Harness();
      await h.run(['--app', _appUri, '--target', 'rpi5-trixie']);
      final project = CrossProjectResolver().resolve(
        h.file('my-app.emb.yaml').path,
      )!;
      expect(project.workspaceDir, p.join(h.out.absolute.path, 'workspace'));
      for (final name in ['rpi5-trixie', 'local']) {
        final target = CrossTarget.fromMap(project.selectTarget(name)!.cross);
        expect(target.package!.flatpak!.appId, 'com.example.MyApp');
      }
    });

    test('the workflow installs the emb that generated it', () async {
      final h = _Harness();
      await h.run(['--app', _appUri]);
      final workflow = h.read('.github/workflows/flatpak.yml');
      expect(workflow, contains('(emb $packageVersion)'));
      expect(
        workflow,
        contains(
          packageVersion.contains('-')
              ? '--source git'
              : 'activate emb_cli $packageVersion',
        ),
      );
    });

    group('arguments', () {
      test('the directory is required', () async {
        final h = _Harness();
        final runner = CommandRunner<int>('emb', 'test')
          ..addCommand(InitCommand(logger: h.logger));
        expect(
          () => runner.run(['init', 'flatpak', '--app-id', 'a.b.C']),
          throwsA(isA<UsageException>()),
        );
      });

      test('a second positional is rejected', () async {
        final h = _Harness();
        expect(() => h.run(['extra']), throwsA(isA<UsageException>()));
        expect(h.written, isEmpty);
      });

      test('--app-id is required', () async {
        final runner = CommandRunner<int>('emb', 'test')
          ..addCommand(InitCommand(logger: _MockLogger()));
        expect(
          () => runner.run(['init', 'flatpak', 'somewhere']),
          throwsA(isA<UsageException>()),
        );
      });

      // The packager's rule. An id it would refuse must not get as far as a
      // generated repo.
      for (final bad in [
        'MyApp',
        'com.example',
        '1com.example.App',
        'a..b.c',
      ]) {
        test('app id "$bad" is refused before anything runs', () async {
          final h = _Harness();
          expect(await h.run(const [], bad), ExitCode.usage.code);
          expect(h.errors.single, contains('Invalid flatpak app id'));
          expect(h.calls, isEmpty);
          expect(h.written, isEmpty);
        });
      }
    });

    group('pinning', () {
      test('HEAD is resolved to a commit, with its branch beside it', () async {
        final h = _Harness();
        await h.run(['--app', _appUri]);

        expect(h.callsTo('git'), [
          ['git', 'ls-remote', '--symref', defaultEmbedderUri, 'HEAD'],
          ['git', 'ls-remote', '--symref', _appUri, 'HEAD'],
        ]);
        expect(h.cross()['source'], {
          'uri': defaultEmbedderUri,
          'rev': _embedderHead,
        });
        expect(h.cross()['app'], {'uri': _appUri, 'rev': _appHead});
        final text = h.read('my-app.emb.yaml');
        expect(text, contains('$_embedderHead # v3.0 when generated'));
        expect(text, contains('$_appHead # main when generated'));
      });

      test('--embedder and --embedder-rev are written as given', () async {
        final h = _Harness();
        await h.run([
          '--embedder',
          'https://example.com/embedder.git',
          '--embedder-rev',
          'cafe',
        ]);
        expect(h.callsTo('git'), isEmpty);
        expect(h.cross()['source'], {
          'uri': 'https://example.com/embedder.git',
          'rev': 'cafe',
        });
      });

      test('--app-rev pins the app without asking git', () async {
        final h = _Harness();
        await h.run(['--app', _appUri, '--app-rev', 'beef']);
        expect(h.callsTo('git'), hasLength(1));
        expect(h.cross()['app'], {'uri': _appUri, 'rev': 'beef'});
      });

      test('an scp-style address is a URI', () async {
        final h = _Harness();
        await h.run(['--app', 'git@example.com:me/app.git', '--app-rev', 'a1']);
        expect(h.cross()['app'], {
          'uri': 'git@example.com:me/app.git',
          'rev': 'a1',
        });
      });

      test('an unresolvable HEAD is unavailable, and writes nothing', () async {
        final h = _Harness(gitFails: true);
        expect(await h.run(), ExitCode.unavailable.code);
        expect(
          h.errors.single,
          allOf(contains('no such repo'), contains('--embedder-rev')),
        );
        expect(h.written, isEmpty);
      });

      test('no git at all is reported, not thrown', () async {
        final h = _Harness(gitMissing: true);
        expect(await h.run(), ExitCode.unavailable.code);
        expect(h.errors.single, contains('git'));
        expect(h.written, isEmpty);
      });
    });

    group('--app <dir>', () {
      Directory app(_Harness h, String pubspec) {
        final dir = Directory(p.join(h.tmp.path, 'app'))..createSync();
        File(p.join(dir.path, 'pubspec.yaml')).writeAsStringSync(pubspec);
        return dir;
      }

      test('name, version and description come from pubspec.yaml', () async {
        final h = _Harness();
        final dir = app(
          h,
          'name: kiosk_app\nversion: 2.3.4+17\n'
          'description: A kiosk.\n',
        );
        expect(await h.run(['--app', dir.path]), ExitCode.success.code);

        expect(h.written, contains('kiosk-app.emb.yaml'));
        final doc = h.manifest('kiosk-app.emb.yaml');
        expect(doc['id'], 'kiosk-app');
        final package = h.cross('kiosk-app.emb.yaml')['package'] as YamlMap;
        expect(package['name'], 'kiosk-app');
        // The build number means nothing to a package version.
        expect(package['version'], '2.3.4');
        final xml = h.read('metainfo.xml');
        expect(xml, contains('<name>kiosk_app</name>'));
        expect(xml, contains('<summary>A kiosk.</summary>'));
        expect(xml, contains('<release version="2.3.4"/>'));
      });

      // A local path is this machine's, so it must not reach the manifest;
      // and with the app outside the repo a runner has nothing to build.
      test('the path is not written, and no workflow is', () async {
        final h = _Harness();
        final dir = app(h, 'name: kiosk_app\n');
        await h.run(['--app', dir.path]);

        expect(h.cross('kiosk-app.emb.yaml').containsKey('app'), isFalse);
        for (final f in h.written.where((f) => !f.endsWith('.png'))) {
          expect(h.read(f), isNot(contains(h.tmp.path)), reason: f);
        }
        expect(h.written, isNot(contains('.github/workflows/flatpak.yml')));
        expect(h.infos, contains(contains('no CI workflow')));
      });

      test('a directory with no pubspec is a usage error', () async {
        final h = _Harness();
        final dir = Directory(p.join(h.tmp.path, 'empty'))..createSync();
        expect(await h.run(['--app', dir.path]), ExitCode.usage.code);
        expect(h.errors.single, contains('pubspec.yaml'));
        expect(h.written, isEmpty);
      });

      test('a pubspec that is not YAML is a usage error', () async {
        final h = _Harness();
        final dir = app(h, 'name: [unterminated\n');
        expect(await h.run(['--app', dir.path]), ExitCode.usage.code);
      });

      test('--app-rev without a URI is a usage error', () async {
        final h = _Harness();
        final dir = app(h, 'name: kiosk_app\n');
        expect(
          await h.run(['--app', dir.path, '--app-rev', 'beef']),
          ExitCode.usage.code,
        );
        expect(await h.run(['--app-rev', 'beef']), ExitCode.usage.code);
      });
    });

    group('--target', () {
      test('adds a target that extends the board', () async {
        final h = _Harness();
        expect(
          await h.run(['--app', _appUri, '--target', 'rpi5-trixie']),
          ExitCode.success.code,
        );
        expect(h.cross()['targets'], {
          'rpi5-trixie': {'extends': 'rpi5-trixie'},
        });
        expect(h.infos, contains(contains('--target rpi5-trixie --build')));
      });

      test('an unknown board is a usage error, and writes nothing', () async {
        final h = _Harness();
        expect(await h.run(['--target', 'no-such-board']), ExitCode.usage.code);
        expect(h.errors.single, contains('no-such-board'));
        // The scratch copy it was checked in is not what the user will have.
        expect(h.errors.single, isNot(contains('emb-init-')));
        expect(h.written, isEmpty);
      });

      // A compiled emb has no board library until `emb boards sync`. That is
      // not a reason to refuse: say so and write the target as asked.
      test('with no board library it warns and still writes', () async {
        final h = _Harness(boards: false);
        expect(await h.run(['--target', 'rpi5-trixie']), ExitCode.success.code);
        expect(h.warnings.single, contains('emb boards sync'));
        expect(h.cross()['targets'], {
          'rpi5-trixie': {'extends': 'rpi5-trixie'},
        });
      });
    });

    group('runtime version', () {
      const listing =
          'org.freedesktop.Platform\t24.08\n'
          'org.freedesktop.Platform\t25.08\n'
          'org.freedesktop.Platform.GL.default\t99.08\n'
          'org.freedesktop.Platform\t25.08-extra\n'
          'org.gnome.Platform\t49\n';

      String runtime(_Harness h) {
        final package = h.cross()['package'] as YamlMap;
        return '${(package['flatpak'] as YamlMap)['runtime_version']}';
      }

      test('defaults to the newest branch flathub offers', () async {
        final h = _Harness(flatpak: {'--user': listing});
        await h.run();
        expect(runtime(h), '25.08');
        expect(h.callsTo('flatpak'), [
          [
            'flatpak',
            'remote-ls',
            '--user',
            '--runtime',
            '--columns=application,branch',
            'flathub',
          ],
        ]);
      });

      test('asks the system installation when the user one has none', () async {
        final h = _Harness(
          flatpak: {'--system': 'org.freedesktop.Platform\t26.08\n'},
        );
        await h.run();
        expect(runtime(h), '26.08');
        expect(h.callsTo('flatpak'), hasLength(2));
      });

      // Not the packager's default of 23.08, which flatpak reports
      // end-of-life.
      test('falls back to a supported constant with no flatpak', () async {
        final h = _Harness();
        await h.run();
        expect(runtime(h), fallbackFlatpakRuntimeVersion);
        expect(fallbackFlatpakRuntimeVersion, isNot('23.08'));
      });

      test('--runtime-version is written as given, flatpak unasked', () async {
        final h = _Harness(flatpak: {'--user': listing});
        await h.run(['--runtime-version', '24.08']);
        expect(runtime(h), '24.08');
        expect(h.callsTo('flatpak'), isEmpty);
      });

      test('is always written, never left to the default', () async {
        final h = _Harness();
        await h.run();
        expect(h.read('my-app.emb.yaml'), contains('runtime_version:'));
      });
    });

    group('the embedder binary', () {
      Object? bin(_Harness h) => (h.cross()['package'] as YamlMap)['bin'];

      test("ivi-homescreen's is known", () async {
        final h = _Harness();
        await h.run();
        expect(bin(h), defaultEmbedderBin);
      });

      // Nothing is known about another embedder's build tree, and a guess
      // that is wrong fails the build.
      test('another embedder gets none, and a note', () async {
        final h = _Harness();
        await h.run(['--embedder', 'https://example.com/embedder.git']);
        expect(bin(h), isNull);
        expect(h.read('my-app.emb.yaml'), contains('# bin: <path>'));
      });

      test('--embedder-bin names it for any embedder', () async {
        final h = _Harness();
        await h.run([
          '--embedder',
          'https://example.com/embedder.git',
          '--embedder-bin',
          'out/shell',
        ]);
        expect(bin(h), 'out/shell');
      });
    });

    test('--flutter-version and --provider are written', () async {
      final h = _Harness();
      await h.run(['--flutter-version', '3.47.9', '--provider', 'yocto-sdk']);
      expect(h.manifest()['flutter_version'], '3.47.9');
      expect(h.cross()['provider'], 'yocto-sdk');
    });

    test('--ci none writes no workflow', () async {
      final h = _Harness();
      await h.run(['--app', _appUri, '--ci', 'none']);
      expect(h.written, isNot(contains('.github/workflows/flatpak.yml')));
      expect(h.infos, isNot(contains(contains('no CI workflow'))));
    });

    group('an existing directory', () {
      test('empty is fine', () async {
        final h = _Harness();
        h.out.createSync();
        expect(await h.run(), ExitCode.success.code);
        expect(h.written, contains('my-app.emb.yaml'));
      });

      // Refused before the network is touched: the answer is already known.
      test('non-empty is refused, before anything runs', () async {
        final h = _Harness();
        h.out.createSync();
        h.file('notes.txt').writeAsStringSync('mine');

        expect(await h.run(), ExitCode.cantCreate.code);
        expect(h.errors.single, contains('--force'));
        expect(h.calls, isEmpty);
        expect(h.written, {'notes.txt'});
      });

      test('--force writes beside what is there', () async {
        final h = _Harness();
        h.out.createSync();
        h.file('notes.txt').writeAsStringSync('mine');

        expect(await h.run(['--force']), ExitCode.success.code);
        expect(h.read('notes.txt'), 'mine');
        expect(h.written, containsAll(['notes.txt', 'my-app.emb.yaml']));
      });

      test('--force never replaces a file emb did not generate', () async {
        final h = _Harness();
        h.out.createSync();
        h.file('README.md').writeAsStringSync('# Mine\n');

        expect(await h.run(['--force']), ExitCode.success.code);
        expect(h.read('README.md'), '# Mine\n');
        expect(h.infos, contains(contains('kept     README.md')));
        expect(h.infos, contains('  wrote    metainfo.xml'));
      });

      test('--force regenerates a file emb did generate', () async {
        final h = _Harness();
        await h.run(['--runtime-version', '24.08']);
        expect(h.read('my-app.emb.yaml'), contains("'24.08'"));

        expect(
          await h.run(['--runtime-version', '25.08', '--force']),
          ExitCode.success.code,
        );
        expect(h.read('my-app.emb.yaml'), contains("'25.08'"));
        expect(h.infos, isNot(contains(contains('kept'))));
      });

      // A binary has no marker line: it is emb's only while it is still
      // exactly what emb wrote.
      test('--force keeps an icon that has been replaced', () async {
        final h = _Harness();
        await h.run();
        h.file('icon.png').writeAsBytesSync([1, 2, 3]);

        await h.run(['--force']);
        expect(h.file('icon.png').readAsBytesSync(), [1, 2, 3]);
        expect(h.infos, contains(contains('kept     icon.png')));
      });

      test('--force leaves an untouched placeholder icon in place', () async {
        final h = _Harness();
        await h.run();
        h.infos.clear();
        await h.run(['--force']);
        expect(h.file('icon.png').readAsBytesSync(), flatpakPlaceholderIcon);
        expect(h.infos, contains('  wrote    icon.png'));
      });

      // Taking a file over is deleting the marker line.
      test("a generated file with its marker removed is the user's", () async {
        final h = _Harness();
        await h.run();
        final edited = h
            .read('.gitignore')
            .split('\n')
            .where((l) => !l.contains(flatpakInitMarker))
            .join('\n');
        h.file('.gitignore').writeAsStringSync(edited);

        await h.run(['--force']);
        expect(h.read('.gitignore'), edited);
      });
    });
  });
}
