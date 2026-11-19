import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:emb_cli/src/cross/cross_project.dart';
import 'package:emb_cli/src/cross/cross_target.dart';
import 'package:emb_cli/src/init/flatpak_repo_template.dart';
import 'package:emb_cli/src/manifest/manifest_loader.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

/// The spec `examples/cross/init-flatpak/` is rendered from. Fixed, not read
/// from the machine or the package version, so the example only changes when
/// a template does.
const exampleSpec = FlatpakRepoSpec(
  appId: 'com.example.MyApp',
  id: 'my-app',
  name: 'My App',
  summary: 'An example Flutter app.',
  embedder: PinnedRepo(
    uri: defaultEmbedderUri,
    rev: 'e48ec1c001c6170bd45a5530bf1c32341a55bf76',
    branch: 'v3.0',
  ),
  embedderBin: defaultEmbedderBin,
  app: PinnedRepo(
    uri: 'https://github.com/me/my_flutter_app.git',
    rev: '76b2c6de449ad27de77f53e5a0c1bf748c79b139',
    branch: 'main',
  ),
  runtimeVersion: '25.08',
  flutterVersion: '3.47.9',
  embVersion: '0.5.0',
  releaseDate: '2026-01-02',
  // One board, as `--target rpi5-trixie` with the default embedder writes it.
  targets: ['rpi5-trixie'],
  backend: defaultEmbedderBackend,
  targetDefines: defaultEmbedderTargetDefines,
  targetDefinesWhy: defaultEmbedderTargetDefinesWhy,
);

final _exampleDir = Directory(p.join('examples', 'cross', 'init-flatpak'));

FlatpakRepoSpec _spec({
  String id = 'my-app',
  String name = 'My App',
  String? summary,
  PinnedRepo? app,
  String embVersion = '1.2.3',
  String? embedderBin,
  bool githubCi = true,
  PinnedRepo embedder = const PinnedRepo(uri: defaultEmbedderUri, rev: 'abc1'),
  List<String> targets = const [],
  String? backend,
  Map<String, String> targetDefines = const {},
}) => FlatpakRepoSpec(
  appId: 'com.example.MyApp',
  id: id,
  name: name,
  summary: summary,
  embedder: embedder,
  embedderBin: embedderBin,
  app: app,
  runtimeVersion: '25.08',
  embVersion: embVersion,
  releaseDate: '2026-01-02',
  githubCi: githubCi,
  targets: targets,
  backend: backend,
  targetDefines: targetDefines,
);

const _app = PinnedRepo(uri: 'https://example.com/app.git', rev: 'def2');

Map<String, dynamic> _manifest(FlatpakRepoSpec spec) =>
    (loadYaml(renderFlatpakRepo(spec)[spec.manifestName]!) as YamlMap)
        .cast<String, dynamic>();

void main() {
  // The templates and the documented example are one thing. A template
  // change that is not also made to the example fails here, so the example
  // cannot go on describing output emb no longer produces.
  group('pinned to examples/cross/init-flatpak', () {
    // Text and binary alike, as the bytes that reach the disk.
    final rendered = <String, List<int>>{
      for (final e in renderFlatpakRepo(exampleSpec).entries)
        e.key: utf8.encode(e.value),
      ...renderFlatpakRepoBinaries(exampleSpec),
    };

    test('every generated file matches the example, byte for byte', () {
      if (Platform.environment['EMB_UPDATE_EXAMPLES'] == '1') {
        for (final e in rendered.entries) {
          File(p.join(_exampleDir.path, e.key))
            ..createSync(recursive: true)
            ..writeAsBytesSync(e.value);
        }
      }
      for (final e in rendered.entries) {
        final file = File(p.join(_exampleDir.path, e.key));
        expect(file.existsSync(), isTrue, reason: 'missing ${file.path}');
        expect(
          file.readAsBytesSync(),
          e.value,
          reason:
              '${file.path} differs from what the template renders. If the '
              'template change is intended, regenerate the example with '
              'EMB_UPDATE_EXAMPLES=1 dart test test/src/init',
        );
      }
    });

    test('the example holds nothing the templates do not render', () {
      final onDisk = {
        for (final f in _exampleDir.listSync(recursive: true))
          if (f is File) p.relative(f.path, from: _exampleDir.path),
      };
      expect(onDisk, rendered.keys.toSet());
    });

    // The bar the generator is held to: what it writes loads the way
    // `emb cross` loads it. Not a build, which needs a toolchain and an
    // engine.
    test('the example manifest resolves as a cross project', () {
      final resolver = CrossProjectResolver(
        const ManifestLoader(),
        Directory('boards'),
        const {},
      );
      final manifest = p.join(_exampleDir.path, exampleSpec.manifestName);
      // The board target extends into the embedder, which is not cloned
      // here: it is set aside, and the native build resolves without it.
      final project = resolver.resolve(manifest, deferExtends: true)!;

      expect(project.id, 'my-app');
      expect(project.flutterVersion, '3.47.9');
      expect(
        project.workspaceDir,
        p.normalize(p.absolute(_exampleDir.path, 'workspace')),
      );
      expect(project.targets, isEmpty);
      expect(project.unresolved.keys, ['rpi5-trixie']);
      final board = project.unresolved['rpi5-trixie']!.block;
      expect(board['extends'], 'source#rpi5-trixie');
      expect(board['defines'], {'DISABLE_PLUGINS': 'ON'});
      expect(CrossTarget.repoFrom(board['source'])!.uri, defaultEmbedderUri);

      for (final name in ['local']) {
        final selection = project.selectTarget(name)!;
        final target = CrossTarget.fromMap(selection.cross);
        final source = CrossTarget.repoFrom(selection.cross['source'])!;
        final app = CrossTarget.repoFrom(selection.cross['app'])!;
        expect(source.uri, defaultEmbedderUri, reason: name);
        expect(source.rev, exampleSpec.embedder.rev, reason: name);
        expect(app.uri, exampleSpec.app!.uri, reason: name);
        expect(app.rev, exampleSpec.app!.rev, reason: name);
        expect(target.package!.name, 'my-app', reason: name);
        expect(target.package!.bin, 'shell/homescreen', reason: name);
        expect(target.package!.flatpak!.appId, 'com.example.MyApp');
        expect(target.package!.flatpak!.runtimeVersion, '25.08');
        expect(target.package!.flatpak!.icon, 'icon.png');
        expect(target.package!.files, {
          'metainfo.xml': '/share/metainfo/com.example.MyApp.metainfo.xml',
        });
      }
    });
  });

  group('rendering', () {
    test('every file carries the marker --force looks for', () {
      for (final spec in [exampleSpec, _spec()]) {
        for (final e in renderFlatpakRepo(spec).entries) {
          expect(e.value, contains(flatpakInitMarker), reason: e.key);
        }
      }
    });

    test('no build script: emb cross is the build script', () {
      final files = renderFlatpakRepo(exampleSpec).keys;
      expect(files.where((f) => f.endsWith('.sh')), isEmpty);
      expect(files, {
        'my-app.emb.yaml',
        'README.md',
        '.gitignore',
        'metainfo.xml',
        '.github/workflows/flatpak.yml',
      });
      expect(renderFlatpakRepoBinaries(exampleSpec).keys, ['icon.png']);
    });

    // appstreamcli, run by flatpak-builder, fails the build of a desktop
    // application whose metadata has no icon or no description. Found by
    // building a generated repo; nothing short of that build shows it.
    group('what flatpak-builder will not build without', () {
      test('an icon the manifest points at', () {
        final flatpak =
            ((_manifest(_spec())['cross'] as YamlMap)['package']
                    as YamlMap)['flatpak']
                as YamlMap;
        expect(flatpak['icon'], 'icon.png');
        expect(
          renderFlatpakRepoBinaries(_spec()).keys,
          contains(flatpak['icon']),
        );
      });

      test('the icon is a 256x256 PNG', () {
        final png = flatpakPlaceholderIcon;
        expect(png.sublist(0, 8), [137, 80, 78, 71, 13, 10, 26, 10]);
        final header = ByteData.sublistView(png, 16, 24);
        expect(header.getUint32(0), 256);
        expect(header.getUint32(4), 256);
      });

      test('a description, placeholder or not', () {
        for (final spec in [_spec(), _spec(summary: 'Does things.')]) {
          final xml = renderFlatpakRepo(spec)['metainfo.xml']!;
          expect(xml, contains(RegExp(r'<description>\s*<p>.+</p>')));
        }
      });
    });

    test('the manifest is named after the id', () {
      expect(_spec(id: 'kiosk').manifestName, 'kiosk.emb.yaml');
      expect(renderFlatpakRepo(_spec(id: 'kiosk')), contains('kiosk.emb.yaml'));
    });

    group('without an app', () {
      final spec = _spec();
      final files = renderFlatpakRepo(spec);

      test('the manifest names none and says how to', () {
        final cross = _manifest(spec)['cross'] as YamlMap;
        expect(cross.containsKey('app'), isFalse);
        expect(files[spec.manifestName], contains('  # app:'));
      });

      test('the build command takes --app', () {
        expect(spec.buildCommand, contains('--app <path-to-your-flutter-app>'));
        expect(files['README.md'], contains(spec.buildCommand));
      });

      // A runner would have nothing to build, and a workflow that cannot
      // pass is worse than none.
      test('no workflow is rendered, even when asked for', () {
        expect(spec.githubCi, isTrue);
        expect(files.keys, isNot(contains('.github/workflows/flatpak.yml')));
      });
    });

    test('with an app: cross.app is pinned, and the build needs no --app', () {
      final spec = _spec(app: _app);
      final cross = _manifest(spec)['cross'] as YamlMap;
      expect(cross['app'], {'uri': _app.uri, 'rev': 'def2'});
      expect(spec.buildCommand, isNot(contains('--app')));
    });

    test('--ci none renders no workflow', () {
      final files = renderFlatpakRepo(_spec(app: _app, githubCi: false));
      expect(files.keys, isNot(contains('.github/workflows/flatpak.yml')));
    });

    test('no target: no targets block, and the build is native', () {
      final spec = _spec(app: _app);
      expect(
        (_manifest(spec)['cross'] as YamlMap).containsKey('targets'),
        isFalse,
      );
      expect(spec.buildCommand, contains('--target local'));
    });

    // Unset, emb has to find the binary, and stops when the build tree
    // holds more than one executable. Naming it is what always works.
    group('package.bin', () {
      YamlMap package(FlatpakRepoSpec spec) =>
          (_manifest(spec)['cross'] as YamlMap)['package'] as YamlMap;

      test('is written when the embedder binary is known', () {
        expect(
          package(_spec(embedderBin: 'shell/homescreen'))['bin'],
          'shell/homescreen',
        );
      });

      test('unknown: left unset, with the reason to set it', () {
        final spec = _spec();
        expect(package(spec).containsKey('bin'), isFalse);
        final text = renderFlatpakRepo(spec)[spec.manifestName]!;
        expect(text, contains('    # bin: <path>'));
        expect(text, contains('more than one'));
      });
    });

    test('the branch a commit came from is a comment beside it', () {
      final text = renderFlatpakRepo(
        _spec(
          embedder: const PinnedRepo(
            uri: defaultEmbedderUri,
            rev: 'abc1',
            branch: 'v3.0',
          ),
        ),
      )['my-app.emb.yaml']!;
      expect(text, contains(RegExp(r'rev: abc1 +# v3\.0 when generated')));
    });

    // Values arrive from flags and from someone else's pubspec. Whatever
    // they are, the manifest must read back as the same strings.
    test('awkward values survive as YAML strings', () {
      const embedder = PinnedRepo(
        uri: 'git@example.com:me/embedder repo.git',
        rev: '1234567',
      );
      const app = PinnedRepo(uri: "https://example.com/o'brien.git", rev: 'no');
      const spec = FlatpakRepoSpec(
        appId: 'com.example.MyApp',
        id: 'true',
        name: 'x',
        version: '1.0',
        embedder: embedder,
        app: app,
        runtimeVersion: '25.08',
        flutterVersion: '3.47',
        embVersion: '1.2.3',
        releaseDate: '2026-01-02',
      );
      final doc = _manifest(spec);
      final cross = doc['cross'] as YamlMap;
      expect(doc['id'], 'true');
      expect(doc['flutter_version'], '3.47');
      expect(cross['source'], {'uri': embedder.uri, 'rev': '1234567'});
      expect(cross['app'], {'uri': app.uri, 'rev': 'no'});
      final package = cross['package'] as YamlMap;
      expect(package['version'], '1.0');
      expect((package['flatpak'] as YamlMap)['runtime_version'], '25.08');
    });

    // A scalar YAML would read as a number is quoted. The manifest parser
    // casts these to String, so an unquoted one is a crash, not a typo.
    for (final rev in ['1234e56', '0x1f', '0o17', '.inf', '1e3', '12_3']) {
      test('rev $rev reads back as a string', () {
        final spec = _spec(
          embedder: PinnedRepo(uri: defaultEmbedderUri, rev: rev),
          embedderBin: rev,
        );
        final cross = _manifest(spec)['cross'] as YamlMap;
        expect((cross['source'] as YamlMap)['rev'], rev);
        expect((cross['package'] as YamlMap)['bin'], rev);
      });
    }

    group('metainfo', () {
      // The version sits in an attribute, where a quote ends the value.
      test('quotes are escaped', () {
        const spec = FlatpakRepoSpec(
          appId: 'com.example.MyApp',
          id: 'my-app',
          name: 'x',
          version: '1.0" date="2020',
          embedder: PinnedRepo(uri: defaultEmbedderUri, rev: 'abc1'),
          runtimeVersion: '25.08',
          embVersion: '1.2.3',
          releaseDate: '2026-01-02',
        );
        final xml = renderFlatpakRepo(spec)['metainfo.xml']!;
        expect(
          xml,
          contains(
            '<release version="1.0&quot; date=&quot;2020" date="2026-01-02"/>',
          ),
        );
      });

      test('name and summary are XML-escaped', () {
        final xml = renderFlatpakRepo(
          _spec(name: 'Tom & <Jerry>', summary: 'a < b & c'),
        )['metainfo.xml']!;
        expect(xml, contains('<name>Tom &amp; &lt;Jerry&gt;</name>'));
        expect(xml, contains('<summary>a &lt; b &amp; c</summary>'));
      });

      // Without a date appstreamcli warns and flatpak drops the element on
      // install, so the version never reaches a software center.
      test('the release is dated', () {
        final xml = renderFlatpakRepo(_spec())['metainfo.xml']!;
        expect(xml, contains('<release version="0.1.0" date="2026-01-02"/>'));
      });

      // Visibly incomplete beats quietly wrong.
      test('the license is a TODO, never a guess', () {
        final xml = renderFlatpakRepo(_spec())['metainfo.xml']!;
        expect(xml, contains('<project_license>TODO</project_license>'));
      });

      test('no summary leaves a placeholder that says so', () {
        final xml = renderFlatpakRepo(_spec())['metainfo.xml']!;
        expect(xml, contains('<summary>TODO: '));
      });
    });

    group('workflow', () {
      Map<dynamic, dynamic> workflow(FlatpakRepoSpec spec) =>
          loadYaml(renderFlatpakRepo(spec)['.github/workflows/flatpak.yml']!)
              as YamlMap;

      List<String> runs(FlatpakRepoSpec spec) => [
        for (final step
            in ((workflow(spec)['jobs'] as YamlMap)['flatpak']
                    as YamlMap)['steps']
                as YamlList)
          if ((step as YamlMap).containsKey('run')) '${step['run']}',
      ];

      // The job runs the embedder's build, the app's and a Flutter SDK.
      // None of it is given a token that can write to the repo.
      test('the token is read-only and not left in the checkout', () {
        final doc = workflow(_spec(app: _app));
        expect(doc['permissions'], {'contents': 'read'});
        final steps =
            ((doc['jobs'] as YamlMap)['flatpak'] as YamlMap)['steps']
                as YamlList;
        final checkout = steps.cast<YamlMap>().firstWhere(
          (s) => '${s['uses']}'.startsWith('actions/checkout@'),
        );
        expect(checkout['with'], {'persist-credentials': false});
      });

      test('is valid YAML that builds this manifest natively', () {
        final build = runs(_spec(app: _app)).last;
        expect(
          build.trim(),
          'emb cross my-app.emb.yaml --target local --build --flatpak',
        );
      });

      test('installs the runtime the manifest names', () {
        final all = runs(_spec(app: _app)).join('\n');
        expect(all, contains('org.freedesktop.Platform//25.08'));
        expect(all, contains('org.freedesktop.Sdk//25.08'));
      });

      test('a release installs itself from pub.dev by version', () {
        expect(
          runs(_spec(app: _app)),
          contains('dart pub global activate emb_cli 1.2.3'),
        );
      });

      // pub.dev has no development build, so naming its version there would
      // write a workflow that fails at its first step.
      test('a development build installs from the repository', () {
        final all = runs(_spec(app: _app, embVersion: '1.3.0-dev')).join('\n');
        expect(all, isNot(contains('emb_cli 1.3.0-dev')));
        expect(all, contains('--source git'));
        expect(all, contains('toyota-connected/emb_cli.git'));
      });

      // A step with a placeholder in it is a shell redirect waiting to run.
      test('no run step carries a placeholder', () {
        for (final run in runs(_spec(app: _app))) {
          expect(run, isNot(contains('<')));
        }
      });
    });
  });

  group('board targets', () {
    test('none: no targets block and no README section', () {
      final spec = _spec(app: _app);
      expect(_manifest(spec)['cross'], isNot(contains('targets')));
      final readme = renderFlatpakRepo(spec)['README.md']!;
      expect(readme, isNot(contains('Build for a board')));
      expect(
        readme,
        contains('flatpak run com.example.MyApp\n```\n\n## Before'),
      );
    });

    test('each extends source#<name>, in order', () {
      final spec = _spec(targets: ['b-board', 'a-board']);
      final targets = (_manifest(spec)['cross'] as Map)['targets'] as Map;
      expect(targets.keys, ['b-board', 'a-board']);
      expect(targets['b-board'], {'extends': 'source#b-board'});
      expect(targets['a-board'], {'extends': 'source#a-board'});
    });

    // `ON` unquoted is a YAML boolean, and a define is a string to CMake.
    test('defines are written as strings', () {
      final spec = _spec(
        targets: ['pi'],
        targetDefines: {'A': 'ON', 'B': '1', 'C': "it's"},
      );
      final target =
          ((_manifest(spec)['cross'] as Map)['targets'] as Map)['pi'] as Map;
      expect(target['defines'], {'A': 'ON', 'B': '1', 'C': "it's"});
    });

    test('the README command names the backend when there is one', () {
      final withBackend = renderFlatpakRepo(
        _spec(app: _app, targets: ['pi'], backend: 'wayland-egl'),
      )['README.md']!;
      expect(
        withBackend,
        contains(
          'emb cross my-app.emb.yaml --target pi --backend wayland-egl '
          '--build --flatpak',
        ),
      );
      final without = renderFlatpakRepo(
        _spec(app: _app, targets: ['pi']),
      )['README.md']!;
      expect(
        without,
        contains('emb cross my-app.emb.yaml --target pi --build --flatpak'),
      );
      expect(without, contains('add `--backend <name>`'));
    });

    test('the native command never names a backend', () {
      final spec = _spec(app: _app, targets: ['pi'], backend: 'wayland-egl');
      expect(
        spec.buildCommand,
        'emb cross my-app.emb.yaml --target local --build --flatpak',
      );
    });

    test('the README names the runtime for the board, at the same branch', () {
      final readme = renderFlatpakRepo(_spec(targets: ['pi']))['README.md']!;
      expect(readme, contains('org.freedesktop.Platform/aarch64/25.08'));
      expect(readme, contains('org.freedesktop.Sdk/aarch64/25.08'));
      expect(readme, contains('qemu-user'));
    });

    test('says CI builds the native one, when there is CI', () {
      const note = 'The CI workflow builds `--target local` only.';
      expect(
        renderFlatpakRepo(_spec(app: _app, targets: ['pi']))['README.md'],
        contains(note),
      );
      expect(
        renderFlatpakRepo(_spec(targets: ['pi']))['README.md'],
        isNot(contains(note)),
      );
    });
  });

  group('naming', () {
    test('idFromAppId kebab-cases the last segment', () {
      expect(idFromAppId('com.example.MyApp'), 'my-app');
      expect(idFromAppId('org.acme.kiosk'), 'kiosk');
      expect(idFromAppId('org.acme.IVIShell2'), 'ivishell2');
    });

    test('kebabCase', () {
      expect(kebabCase('hello_app'), 'hello-app');
      expect(kebabCase('My  Great App'), 'my-great-app');
      expect(kebabCase('_x_'), 'x');
      expect(kebabCase('___'), '');
    });
  });
}
