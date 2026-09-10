import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:emb_cli/src/commands/init_command.dart';
import 'package:emb_cli/src/manifest/manifest_loader.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('emb_initfp_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  Future<int?> run(List<String> args) {
    final runner = CommandRunner<int>('emb', 'test')
      ..addCommand(InitCommand(logger: Logger()));
    return runner.run(['init', 'flatpak', ...args]);
  }

  String read(String dir, String rel) =>
      File(p.join(dir, rel)).readAsStringSync();

  /// Every path the generator promises to write.
  const expected = [
    'scripts/build.sh',
    'emb-src/ivi-homescreen-src/emb.yaml',
    '.github/actions/build-embedder/action.yml',
    '.github/workflows/ci.yml',
    'versions.env',
    '.gitignore',
    'README.md',
  ];

  test('writes a complete repo', () async {
    final out = p.join(tmp.path, 'repo');
    expect(
      await run([out, '--app-id', 'com.example.App']),
      ExitCode.success.code,
    );
    for (final rel in [
      ...expected,
      'emb/app.emb.yaml',
      'emb/com.example.App.appdata.xml',
    ]) {
      expect(File(p.join(out, rel)).existsSync(), isTrue, reason: rel);
    }
  });

  test("the generated manifest survives emb's own loader", () async {
    final out = p.join(tmp.path, 'repo');
    await run([out, '--app-id', 'com.example.App']);
    // A generator change that emits unparseable YAML, or a key the cross
    // parser rejects, has to fail here rather than in a user's first build.
    final manifest = const ManifestLoader().loadManifestFile(
      File(p.join(out, 'emb', 'app.emb.yaml')),
    );
    expect(manifest, isNotNull, reason: 'manifest did not load');
    final target = manifest!.cross;
    expect(target, isNotNull, reason: 'cross: block did not parse');
    final fp = target!.package!.flatpak!;
    expect(fp.appId, 'com.example.App');
    expect(fp.runtimeVersion, '25.08');
    expect(fp.vendorLibs, isTrue);
    expect(fp.env['LD_LIBRARY_PATH'], '/app/com.example.App/lib');
    expect(fp.args, contains('--app-id=com.example.App'));
    expect(target.package!.bin, 'shell/homescreen');
  });

  test('the app id reaches every place that needs it', () async {
    final out = p.join(tmp.path, 'repo');
    await run([out, '--app-id', 'com.example.App']);
    final manifest = read(out, 'emb/app.emb.yaml');
    expect(manifest, contains('app_id: com.example.App'));
    expect(manifest, contains('--app-id=com.example.App'));
    expect(manifest, contains('LD_LIBRARY_PATH: /app/com.example.App/lib'));
    final appdata = read(out, 'emb/com.example.App.appdata.xml');
    expect(appdata, contains('<id>com.example.App</id>'));
    expect(appdata, contains('com.example.App.desktop'));
    expect(read(out, 'README.md'), contains('flatpak run com.example.App'));
  });

  test('a generated repo carries no trace of another app', () async {
    final out = p.join(tmp.path, 'repo');
    await run([out, '--app-id', 'org.acme.Widget', '--app-name', 'Widget']);
    // The whole point of the generator: nothing app-, vendor- or
    // machine-specific from wherever it was authored may leak in.
    for (final entity in Directory(out).listSync(recursive: true)) {
      if (entity is! File) continue;
      final text = entity.readAsStringSync();
      for (final leak in const [
        'com.example',
        'flutter_remote_manager',
        'flatpak-app-store',
        '/home/',
      ]) {
        expect(
          text,
          isNot(contains(leak)),
          reason: '${entity.path} leaks $leak',
        );
      }
    }
  });

  test('infers name, version and summary from the app pubspec', () async {
    final app = Directory(p.join(tmp.path, 'app'))..createSync();
    File(p.join(app.path, 'pubspec.yaml')).writeAsStringSync(
      'name: widget_app\nversion: 2.5.1\ndescription: Does widget things.\n',
    );
    final out = p.join(tmp.path, 'repo');
    expect(
      await run([out, '--app-id', 'org.acme.Widget', '--app', app.path]),
      ExitCode.success.code,
    );
    final manifest = read(out, 'emb/widget.emb.yaml');
    expect(manifest, contains('name: widget_app'));
    expect(manifest, contains('version: 2.5.1'));
    expect(
      read(out, 'emb/org.acme.Widget.appdata.xml'),
      contains('Does widget things.'),
    );
  });

  test('an explicit flag beats the pubspec', () async {
    final app = Directory(p.join(tmp.path, 'app'))..createSync();
    File(
      p.join(app.path, 'pubspec.yaml'),
    ).writeAsStringSync('name: from_pubspec\nversion: 9.9.9\n');
    final out = p.join(tmp.path, 'repo');
    await run([
      out,
      '--app-id',
      'org.acme.Widget',
      '--app',
      app.path,
      '--app-name',
      'From Flag',
      '--app-version',
      '1.2.3',
    ]);
    final manifest = read(out, 'emb/widget.emb.yaml');
    expect(manifest, contains('name: From Flag'));
    expect(manifest, contains('version: 1.2.3'));
  });

  test(
    'sandbox defaults to the narrow Wayland set, never a wide one',
    () async {
      final out = p.join(tmp.path, 'repo');
      await run([out, '--app-id', 'com.example.App']);
      final manifest = read(out, 'emb/app.emb.yaml');
      expect(manifest, contains('- --socket=wayland'));
      // Permissions are the one field where a generous default is a security
      // bug: an app that manages flatpaks or needs the network says so itself.
      for (final wide in const [
        '--talk-name=org.freedesktop.Flatpak',
        '--socket=system-bus',
        '--filesystem=',
        '--share=network',
      ]) {
        expect(manifest, isNot(contains(wide)), reason: wide);
      }
    },
  );

  test('embedder specifics are scoped to the embedder', () async {
    final ihs = p.join(tmp.path, 'ihs');
    final other = p.join(tmp.path, 'other');
    await run([ihs, '--app-id', 'com.example.App']);
    await run([
      other,
      '--app-id',
      'com.example.App',
      '--embedder',
      'flutter-auto',
    ]);
    // agl_shell is a fact about ivi-homescreen, not about every app.
    expect(read(ihs, 'emb/app.emb.yaml'), contains('ENABLE_AGL_SHELL_CLIENT'));
    expect(
      read(other, 'emb/app.emb.yaml'),
      isNot(contains('ENABLE_AGL_SHELL_CLIENT')),
    );
    expect(
      read(other, 'emb/app.emb.yaml'),
      contains('bin: shell/flutter-auto'),
    );
  });

  test('--backend flows into the matrix, defines and launcher args', () async {
    final out = p.join(tmp.path, 'repo');
    await run([out, '--app-id', 'com.example.App', '--backend', 'drm-kms-egl']);
    final doc = loadYaml(read(out, 'emb/app.emb.yaml')) as YamlMap;
    final cross = doc['cross'] as YamlMap;
    expect((cross['backends'] as YamlMap).keys, ['drm-kms-egl']);
    expect(
      (cross['backends'] as YamlMap)['drm-kms-egl'],
      containsPair('BUILD_BACKEND_DRM_KMS_EGL', 'ON'),
    );
    expect(read(out, 'emb/app.emb.yaml'), contains('--backend=drm-kms-egl'));
  });

  test('the icon key is emitted only when an icon is supplied', () async {
    final without = p.join(tmp.path, 'without');
    await run([without, '--app-id', 'com.example.App']);
    // Never invent a PNG; leave the key commented with an instruction.
    expect(read(without, 'emb/app.emb.yaml'), contains('# icon:'));
    expect(
      File(p.join(without, 'emb', 'com.example.App.png')).existsSync(),
      isFalse,
    );

    final icon = File(p.join(tmp.path, 'logo.png'))
      ..writeAsBytesSync([1, 2, 3]);
    final with_ = p.join(tmp.path, 'with');
    await run([with_, '--app-id', 'com.example.App', '--icon', icon.path]);
    expect(
      read(with_, 'emb/app.emb.yaml'),
      contains('icon: com.example.App.png'),
    );
    expect(
      File(p.join(with_, 'emb', 'com.example.App.png')).existsSync(),
      isTrue,
    );
  });

  test('build.sh is executable and syntactically valid', () async {
    final out = p.join(tmp.path, 'repo');
    await run([out, '--app-id', 'com.example.App']);
    final script = File(p.join(out, 'scripts', 'build.sh'));
    if (!Platform.isWindows) {
      final stat = script.statSync();
      expect(stat.mode & 0x40, isNot(0), reason: 'owner execute bit');
      expect(
        Process.runSync('bash', ['-n', script.path]).exitCode,
        0,
        reason: 'bash -n',
      );
    }
    final text = script.readAsStringSync();
    // It must source the workspace env, or builds reach into the user's
    // global pub cache instead of the workspace-scoped one...
    expect(text, contains('setup_env.sh'));
    // ...but setup_env.sh bakes an absolute FLUTTER_WORKSPACE, so a copied
    // repo would silently build into whichever workspace the file was written
    // against. Regenerating it first is what makes the script relocatable.
    expect(text, contains(r'emb env -w "$FLUTTER_WORKSPACE"'));
    expect(
      text.indexOf('emb env -w'),
      lessThan(text.indexOf(r'. "$FLUTTER_WORKSPACE/setup_env.sh"')),
      reason: 'must regenerate before sourcing',
    );
    // A cold workspace has no bin/cache until a flutter command runs, and emb
    // probes that cache to choose a frontend_server before it invokes flutter
    // — so the first build of a fresh workspace fails unless the script warms
    // it. Regression: this step was dropped once and only cold runs caught it.
    expect(text, contains('precache --linux --no-universal'));
    expect(
      text.indexOf('precache'),
      lessThan(text.indexOf('emb cross')),
      reason: 'must precache before building',
    );
  });

  group('input validation', () {
    test('a non-reverse-DNS app id is a usage error', () async {
      final out = p.join(tmp.path, 'repo');
      expect(await run([out, '--app-id', 'notanid']), ExitCode.usage.code);
      expect(Directory(out).existsSync(), isFalse, reason: 'no partial repo');
    });

    test('a missing app id is a usage error', () async {
      expect(await run([p.join(tmp.path, 'r')]), ExitCode.usage.code);
    });

    test('a missing target dir is a usage error', () async {
      expect(await run(['--app-id', 'com.example.App']), ExitCode.usage.code);
    });

    test('a non-empty target needs --force', () async {
      final out = Directory(p.join(tmp.path, 'repo'))..createSync();
      File(p.join(out.path, 'keep.txt')).writeAsStringSync('mine');
      expect(
        await run([out.path, '--app-id', 'com.example.App']),
        ExitCode.usage.code,
      );
      expect(File(p.join(out.path, 'README.md')).existsSync(), isFalse);

      expect(
        await run([out.path, '--app-id', 'com.example.App', '--force']),
        ExitCode.success.code,
      );
      expect(File(p.join(out.path, 'README.md')).existsSync(), isTrue);
      expect(
        File(p.join(out.path, 'keep.txt')).existsSync(),
        isTrue,
        reason: '--force overwrites generated files, not everything',
      );
    });

    test('a missing --icon is a usage error', () async {
      expect(
        await run([
          p.join(tmp.path, 'r'),
          '--app-id',
          'com.example.App',
          '--icon',
          p.join(tmp.path, 'nope.png'),
        ]),
        ExitCode.usage.code,
      );
    });

    test(
      'a malformed pubspec degrades to defaults rather than failing',
      () async {
        final app = Directory(p.join(tmp.path, 'app'))..createSync();
        File(p.join(app.path, 'pubspec.yaml')).writeAsStringSync('{[not yaml');
        final out = p.join(tmp.path, 'repo');
        expect(
          await run([out, '--app-id', 'com.example.App', '--app', app.path]),
          ExitCode.success.code,
        );
        expect(read(out, 'emb/app.emb.yaml'), contains('version: 1.0.0'));
      },
    );
  });
  group('embedder source', () {
    test('is pinned in emb-src/, and only there', () async {
      final out = p.join(tmp.path, 'repo');
      await run([
        out,
        '--app-id',
        'com.example.App',
        '--homescreen-ref',
        'abc123def456',
      ]);
      final src = read(out, 'emb-src/ivi-homescreen-src/emb.yaml');
      final m = const ManifestLoader().loadManifestFile(
        File(p.join(out, 'emb-src', 'ivi-homescreen-src', 'emb.yaml')),
      );
      expect(m!.src.single.rev, 'abc123def456');
      expect(m.src.single.branch, isNull);
      expect(src, contains('submodules: true'));
      expect(src, contains('ivi-homescreen.git'));
      // One pin, not two: versions.env used to carry a second copy that could
      // drift away from the one emb sync actually clones.
      expect(read(out, 'versions.env'), isNot(contains('abc123def456')));
      expect(read(out, 'versions.env'), isNot(contains('IVI_HOMESCREEN_REF')));
    });

    test('parses as a manifest emb sync can consume', () async {
      final out = p.join(tmp.path, 'repo');
      await run([out, '--app-id', 'com.example.App']);
      final m = const ManifestLoader().loadManifestFile(
        File(p.join(out, 'emb-src', 'ivi-homescreen-src', 'emb.yaml')),
      );
      expect(m, isNotNull, reason: 'emb sync would find no repositories');
      expect(m!.src, hasLength(1));
      expect(m.src.single.uri, endsWith('ivi-homescreen.git'));
      expect(m.src.single.recurseSubmodules, isTrue);
      // One of the two must name a ref, or emb sync has nothing to check out.
      expect(m.src.single.rev ?? m.src.single.branch, isNotNull);
    });

    test('a branch is written as branch:, not dressed up as a pin', () async {
      final out = p.join(tmp.path, 'repo');
      await run([out, '--app-id', 'com.example.App']); // default ref is `main`
      final src = read(out, 'emb-src/ivi-homescreen-src/emb.yaml');
      // `rev: main` would claim reproducibility the ref cannot deliver — every
      // build would get whatever the branch tip happened to be that day.
      expect(src, contains('branch: main'));
      expect(src, isNot(contains('    rev: main')));
      final m = const ManifestLoader().loadManifestFile(
        File(p.join(out, 'emb-src', 'ivi-homescreen-src', 'emb.yaml')),
      );
      expect(m!.src.single.branch, 'main');
      expect(m.src.single.rev, isNull);
    });

    test('build.sh syncs it and does not demand IHS_DIR', () async {
      final out = p.join(tmp.path, 'repo');
      await run([out, '--app-id', 'com.example.App']);
      final script = read(out, 'scripts/build.sh');
      expect(script, contains('emb sync -p'));
      // IHS_DIR stays an override, never a required input.
      expect(script, isNot(contains(r'${IHS_DIR:?')));
      expect(script, contains(r'if [[ -z "${IHS_DIR:-}" ]]'));
    });

    test('CI delegates the checkout instead of doing its own', () async {
      final out = p.join(tmp.path, 'repo');
      await run([out, '--app-id', 'com.example.App']);
      final action = read(out, '.github/actions/build-embedder/action.yml');
      expect(action, isNot(contains('homescreen-ref')));
      expect(action, isNot(contains('repository: ')));
      expect(read(out, '.github/workflows/ci.yml'), isNot(contains('IHS_DIR')));
    });
  });

  test('build.sh resolves the app before building', () async {
    final out = p.join(tmp.path, 'repo');
    await run([out, '--app-id', 'com.example.App']);
    final script = read(out, 'scripts/build.sh');
    // emb expects a resolved app and says so rather than resolving one. This
    // repo scopes PUB_CACHE to its own workspace, so an app resolved elsewhere
    // has a package_config pointing at packages this cache does not hold.
    expect(script, contains('pub get --directory'));
    expect(
      script.indexOf('pub get --directory'),
      lessThan(script.indexOf('emb cross')),
      reason: 'must resolve before building',
    );
  });
  test(r'versions.env survives being fed to $GITHUB_ENV', () async {
    final out = p.join(tmp.path, 'repo');
    await run([out, '--app-id', 'com.example.App']);
    final env = read(out, 'versions.env');
    expect(env, contains('#'), reason: 'the file is meant to be commented');
    expect(read(out, '.github/workflows/ci.yml'), contains('grep -Ev'));

    // Every line the workflow would actually export must be KEY=value.
    final exported = const LineSplitter()
        .convert(env)
        .where((l) => !RegExp(r'^\s*(#|$)').hasMatch(l));
    for (final line in exported) {
      expect(
        line,
        matches('^[A-Za-z_][A-Za-z0-9_]*='),
        reason: r'$GITHUB_ENV would reject: ' + line,
      );
    }
  });
  test(
    'CI installs elfutils, which flatpak-builder needs for eu-strip',
    () async {
      final out = p.join(tmp.path, 'repo');
      await run([out, '--app-id', 'com.example.App']);
      // flatpak-builder shells out to eu-strip and fails the build with
      // "No such file or directory" when elfutils is absent.
      expect(
        read(out, '.github/actions/build-embedder/action.yml'),
        contains('elfutils'),
      );
    },
  );
}
