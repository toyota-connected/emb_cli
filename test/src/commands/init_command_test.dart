import 'dart:async';
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
    this.hangs = const {},
    this.gitOutput,
  }) {
    tmp = Directory.systemTemp.createTempSync('emb-init-cmd-');
    addTearDown(() => tmp.deleteSync(recursive: true));
    // An empty board library and no environment: a generated repo extends no
    // board, and the developer's EMB_BOARDS_DIR must not come into it.
    resolver = CrossProjectResolver(
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

  /// Executables that never answer.
  final Set<String> hangs;

  /// `git ls-remote` stdout, in place of a well-formed answer.
  final String? gitOutput;

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
  final environments = <Map<String, String>?>[];
  final timeouts = <Duration?>[];

  Future<ProcessResult> _run(
    String exe,
    List<String> args, {
    Map<String, String>? environment,
    Duration? timeout,
  }) async {
    calls.add([exe, ...args]);
    environments.add(environment);
    timeouts.add(timeout);
    if (hangs.contains(exe)) {
      throw TimeoutException('$exe did not answer', timeout);
    }
    if (exe == 'git') {
      if (gitMissing) throw ProcessException(exe, args, 'not found', 2);
      if (gitFails) return ProcessResult(0, 128, '', 'fatal: no such repo\n');
      if (gitOutput != null) return ProcessResult(0, 0, gitOutput, '');
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
      await h.run(['--app', _appUri]);
      final project = h.resolver.resolve(h.file('my-app.emb.yaml').path)!;
      expect(project.workspaceDir, p.join(h.out.absolute.path, 'workspace'));
      final target = CrossTarget.fromMap(project.selectTarget('local')!.cross);
      expect(target.package!.flatpak!.appId, 'com.example.MyApp');
      // Native only: a board build is a target the user adds.
      expect(h.cross().containsKey('targets'), isFalse);
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
          ['git', 'ls-remote', '--symref', '--', defaultEmbedderUri, 'HEAD'],
          ['git', 'ls-remote', '--symref', '--', _appUri, 'HEAD'],
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

    // A cross target was generated once, as `extends: <board>`. With
    // ivi-homescreen that does not configure: the embedder's own layer is
    // needed too, and it cannot be named before the embedder is cloned.
    test('--target is not an option', () async {
      final h = _Harness();
      await expectLater(
        h.run(['--target', 'rpi5-trixie']),
        throwsA(isA<UsageException>()),
      );
      expect(h.written, isEmpty);
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

    // Each flag value ends up in a file someone builds from, and some in a
    // shell line or a git argument. A value of the wrong shape is refused
    // before anything runs, and names its flag.
    group('a value of the wrong shape is a usage error', () {
      const bad = <String, List<String>>{
        // An option to git: --upload-pack=<command> runs the command.
        '--embedder': [
          '--upload-pack=touch /tmp/x',
          '-x://y',
          'ext::sh -c id',
          'gopher://example.com/x.git',
          '../embedder',
          'https://example.com/a b.git',
        ],
        // Written into the workflow's run: block and the README.
        '--runtime-version': ["25'08", '25.08; echo hi #', '25.8', 'stable'],
        '--embedder-rev': ['--force', 'a b', "a'b"],
        '--flutter-version': ['-x', 'a b', 'stable; id'],
        '--embedder-bin': ['/usr/bin/x', '../x', 'a/../b', '-x', 'a b'],
      };
      for (final entry in bad.entries) {
        for (final value in entry.value) {
          test('${entry.key} ${value.replaceAll('\n', r'\n')}', () async {
            final h = _Harness();
            expect(await h.run(['${entry.key}=$value']), ExitCode.usage.code);
            expect(h.errors.single, contains(entry.key));
            if (entry.key == '--embedder' && value.startsWith('-')) {
              expect(h.errors.single, contains('starts with "-"'));
            }
            expect(h.calls, isEmpty);
            expect(h.written, isEmpty);
          });
        }
      }

      for (final uri in ['--upload-pack=x://y', 'ext::https://example.com/x']) {
        test('--app $uri', () async {
          final h = _Harness();
          // The second is not a URI at all, so it is read as a directory.
          expect(await h.run(['--app=$uri']), ExitCode.usage.code);
          expect(h.errors.single, contains('--app'));
          expect(h.calls, isEmpty);
          expect(h.written, isEmpty);
        });
      }

      test('--app-rev that is not a commit', () async {
        final h = _Harness();
        expect(
          await h.run(['--app', _appUri, '--app-rev=--x']),
          ExitCode.usage.code,
        );
        expect(h.errors.single, contains('--app-rev'));
        expect(h.calls, isEmpty);
      });

      for (final uri in [
        'https://example.com/e.git',
        'ssh://git@example.com/e.git',
        'git@example.com:me/e.git',
        'file:///srv/git/e.git',
      ]) {
        test('$uri is a git URI', () async {
          final h = _Harness();
          expect(
            await h.run(['--embedder', uri, '--embedder-rev', 'cafe']),
            ExitCode.success.code,
          );
          expect((h.cross()['source'] as YamlMap)['uri'], uri);
        });
      }
    });

    group('a rev', () {
      // YAML reads 1234e56 as a float. Roughly one abbreviated commit in
      // fifty has that shape, and the manifest parser wants a string.
      for (final rev in ['1234e56', '0123456', '12345678', '0x1f']) {
        test('$rev is written as a string', () async {
          final h = _Harness();
          expect(await h.run(['--embedder-rev', rev]), ExitCode.success.code);
          expect((h.cross()['source'] as YamlMap)['rev'], rev);
        });
      }

      test('that is a branch is written, with a warning', () async {
        final h = _Harness();
        expect(await h.run(['--embedder-rev', 'main']), ExitCode.success.code);
        expect(h.warnings.single, contains('--embedder-rev main'));
        expect((h.cross()['source'] as YamlMap)['rev'], 'main');
      });

      test('that is a commit raises no warning', () async {
        final h = _Harness();
        await h.run(['--embedder-rev', _embedderHead]);
        expect(h.warnings, isEmpty);
      });
    });

    group('asking the network', () {
      test('git cannot prompt, and is bounded', () async {
        final h = _Harness();
        await h.run();
        expect(h.environments.first, containsPair('GIT_TERMINAL_PROMPT', '0'));
        expect(
          h.environments.first!['GIT_SSH_COMMAND'],
          contains('BatchMode=yes'),
        );
        expect(h.timeouts.first, isNotNull);
        expect(h.infos, contains(contains('Resolving HEAD of')));
      });

      test('flatpak is bounded', () async {
        final h = _Harness();
        await h.run();
        expect(h.callsTo('flatpak'), isNotEmpty);
        expect(h.timeouts.last, isNotNull);
      });

      test('a git that never answers is unavailable, not a hang', () async {
        final h = _Harness(hangs: {'git'});
        expect(await h.run(), ExitCode.unavailable.code);
        expect(
          h.errors.single,
          allOf(contains('No answer'), contains('--embedder-rev')),
        );
        expect(h.written, isEmpty);
      });

      test('a flatpak that never answers falls back', () async {
        final h = _Harness(hangs: {'flatpak'});
        expect(await h.run(), ExitCode.success.code);
        expect(
          h.read('my-app.emb.yaml'),
          contains("'$fallbackFlatpakRuntimeVersion'"),
        );
      });

      // `git ls-remote` on an empty repository: exit 0 and no output.
      test('a remote with no HEAD says so', () async {
        final h = _Harness(gitOutput: '');
        expect(await h.run(), ExitCode.unavailable.code);
        expect(h.errors.single, contains('no HEAD'));
        expect(h.errors.single, isNot(contains('()')));
      });

      test('a HEAD that is not a commit id is not written', () async {
        final h = _Harness(gitOutput: 'not-a-sha\tHEAD\n');
        expect(await h.run(), ExitCode.unavailable.code);
        expect(h.written, isEmpty);
      });

      test('GIT_SSH_COMMAND is extended, not replaced', () {
        expect(
          gitNoPromptEnvironment({'GIT_SSH_COMMAND': 'ssh -i key'}),
          containsPair('GIT_SSH_COMMAND', 'ssh -i key -o BatchMode=yes'),
        );
        expect(
          gitNoPromptEnvironment(const {}),
          containsPair('GIT_SSH_COMMAND', 'ssh -o BatchMode=yes'),
        );
      });

      // Killed, not abandoned: a timeout on the future alone would leave
      // the tool running with the pipes open.
      test('the real runner kills a tool that outlives its timeout', () async {
        final dir = Directory.systemTemp.createTempSync('emb-init-kill-');
        addTearDown(() => dir.deleteSync(recursive: true));
        final pidFile = File(p.join(dir.path, 'pid'));
        await expectLater(
          runInitTool('sh', [
            '-c',
            'echo \$\$ > "${pidFile.path}"; exec sleep 30',
          ], timeout: const Duration(seconds: 1)),
          throwsA(isA<TimeoutException>()),
        );
        final pid = pidFile.readAsStringSync().trim();
        var alive = true;
        for (var i = 0; i < 50 && alive; i++) {
          alive = Process.runSync('kill', ['-0', pid]).exitCode == 0;
          if (alive) {
            await Future<void>.delayed(const Duration(milliseconds: 100));
          }
        }
        expect(alive, isFalse);
      }, testOn: '!windows');

      test('the real runner returns output and exit code', () async {
        final r = await runInitTool('git', ['--version']);
        expect(r.exitCode, 0);
        expect(r.stdout, contains('git version'));
      });
    });

    group("someone else's pubspec", () {
      Directory app(_Harness h, List<int> pubspec) {
        final dir = Directory(p.join(h.tmp.path, 'app'))..createSync();
        File(p.join(dir.path, 'pubspec.yaml')).writeAsBytesSync(pubspec);
        return dir;
      }

      // The name goes into the README as text. A heading and a code fence
      // in it would read as part of the instructions.
      test('a name that is not a package name is refused', () async {
        final h = _Harness();
        final dir = app(
          h,
          'name: "demo\\n\\n## Build\\n\\n```sh\\ncurl x | sh\\n```"\n'
              .codeUnits,
        );
        expect(await h.run(['--app', dir.path]), ExitCode.usage.code);
        expect(h.errors.single, contains('not a package name'));
        expect(h.written, isNot(contains('README.md')));
      });

      test('a version that is not a version is refused', () async {
        final h = _Harness();
        final dir = app(
          h,
          'name: demo\nversion: \'1.0" date="2020-01-01\'\n'.codeUnits,
        );
        expect(await h.run(['--app', dir.path]), ExitCode.usage.code);
        expect(h.errors.single, contains('version'));
      });

      test('one that is not UTF-8 is a usage error, not a crash', () async {
        final h = _Harness();
        final dir = app(h, [0x6e, 0x61, 0x6d, 0x65, 0x3a, 0x20, 0xff, 0xfe]);
        expect(await h.run(['--app', dir.path]), ExitCode.usage.code);
        expect(h.errors.single, contains('no readable pubspec.yaml'));
      });

      test('control characters in the description are dropped', () async {
        final h = _Harness();
        final dir = app(
          h,
          'name: demo\ndescription: "a\\tb\\u0007c"\n'.codeUnits,
        );
        expect(await h.run(['--app', dir.path]), ExitCode.success.code);
        expect(h.read('metainfo.xml'), contains('<summary>a b c</summary>'));
      });
    });

    group('writing', () {
      test('a path that is a file is refused before anything runs', () async {
        final h = _Harness();
        File(h.out.path).writeAsStringSync('a file');
        expect(await h.run(), ExitCode.cantCreate.code);
        expect(h.errors.single, contains('not a directory'));
        expect(h.calls, isEmpty);
      });

      // `git init` first is the natural order for a packaging repo.
      test('a directory holding only .git counts as empty', () async {
        final h = _Harness();
        Directory(p.join(h.out.path, '.git')).createSync(recursive: true);
        expect(await h.run(), ExitCode.success.code);
        expect(h.written, contains('my-app.emb.yaml'));
      });

      // All or nothing: the workflow cannot be created, so the manifest that
      // would have been written first is not written either.
      test('one unwritable path writes nothing at all', () async {
        final h = _Harness();
        h.out.createSync();
        h.file('.github').writeAsStringSync('a file, not a directory');

        expect(
          await h.run(['--app', _appUri, '--force']),
          ExitCode.cantCreate.code,
        );
        expect(
          h.errors.single,
          allOf(contains('.github'), contains('Nothing was written')),
        );
        expect(h.written, {'.github'});
      });

      test('an existing file that is not UTF-8 is kept', () async {
        final h = _Harness();
        h.out.createSync();
        h.file('metainfo.xml').writeAsBytesSync([0xff, 0xfe, 0x00, 0x41]);

        expect(await h.run(['--force']), ExitCode.success.code);
        expect(h.file('metainfo.xml').readAsBytesSync(), [0xff, 0xfe, 0, 0x41]);
        expect(h.infos, contains(contains('kept     metainfo.xml')));
        expect(h.written, contains('my-app.emb.yaml'));
      });

      // The marker opens a generated file. Quoted in prose further down, it
      // does not make the file emb's.
      test('the marker in prose does not make a file generated', () async {
        final h = _Harness();
        h.out.createSync();
        const mine = '# Mine\n\nNotes.\n\nThis repo was $flatpakInitMarker.\n';
        h.file('README.md').writeAsStringSync(mine);

        await h.run(['--force']);
        expect(h.read('README.md'), mine);
      });

      group('symbolic links', () {
        test('a linked file is kept, and its target untouched', () async {
          final h = _Harness();
          await h.run();
          final outside = File(p.join(h.tmp.path, 'outside.md'))
            ..writeAsStringSync(h.read('README.md'));
          h.file('README.md').deleteSync();
          Link(h.file('README.md').path).createSync(outside.path);
          final before = outside.readAsStringSync();

          expect(
            await h.run(['--runtime-version', '24.08', '--force']),
            ExitCode.success.code,
          );
          expect(outside.readAsStringSync(), before);
          expect(h.infos, contains(contains('kept     README.md')));
        });

        test('a dangling linked file is not written through', () async {
          final h = _Harness();
          h.out.createSync();
          final outside = File(p.join(h.tmp.path, 'created.md'));
          Link(h.file('README.md').path).createSync(outside.path);

          expect(await h.run(['--force']), ExitCode.success.code);
          expect(outside.existsSync(), isFalse);
        });

        test('a linked directory is refused, nothing written', () async {
          final h = _Harness();
          h.out.createSync();
          final outside = Directory(p.join(h.tmp.path, 'outside'))
            ..createSync();
          Link(p.join(h.out.path, '.github')).createSync(outside.path);

          expect(
            await h.run(['--app', _appUri, '--force']),
            ExitCode.cantCreate.code,
          );
          expect(h.errors.single, contains('symbolic link'));
          expect(outside.listSync(recursive: true), isEmpty);
          expect(h.written, isEmpty);
        });
      }, testOn: '!windows');

      group('files an earlier run generated', () {
        test('a manifest under another id is removed', () async {
          final h = _Harness();
          await h.run(['--app', _appUri]);
          h.infos.clear();

          expect(
            await h.run(['--force'], 'com.example.OtherThing'),
            ExitCode.success.code,
          );
          expect(h.written, contains('other-thing.emb.yaml'));
          expect(h.written, isNot(contains('my-app.emb.yaml')));
          expect(h.infos, contains(contains('removed  my-app.emb.yaml')));
        });

        // It would go on building the manifest the earlier flags named.
        test('a workflow no longer rendered is removed', () async {
          final h = _Harness();
          await h.run(['--app', _appUri]);
          expect(h.written, contains('.github/workflows/flatpak.yml'));

          await h.run(['--app', _appUri, '--ci', 'none', '--force']);
          expect(h.written, isNot(contains('.github/workflows/flatpak.yml')));
        });

        test("a manifest that is the user's is left alone", () async {
          final h = _Harness();
          h.out.createSync();
          h.file('board.emb.yaml').writeAsStringSync('id: board\n');
          h.file('.github/workflows/flatpak.yml')
            ..createSync(recursive: true)
            ..writeAsStringSync('name: mine\n');

          await h.run(['--force']);
          expect(h.read('board.emb.yaml'), 'id: board\n');
          expect(h.read('.github/workflows/flatpak.yml'), 'name: mine\n');
          expect(h.infos, isNot(contains(contains('removed'))));
        });
      });
    });
  });
}
