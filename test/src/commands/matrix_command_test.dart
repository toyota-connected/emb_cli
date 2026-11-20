import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:emb_cli/src/commands/matrix_command.dart';
import 'package:emb_cli/src/cross/cross_project.dart';
import 'package:emb_cli/src/host/host_info.dart';
import 'package:emb_cli/src/manifest/manifest_loader.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

class _CapturingLogger extends Logger {
  final StringBuffer warnings = StringBuffer();
  @override
  void warn(String? message, {String tag = 'WARN', LogStyle? style}) =>
      warnings.writeln(message);
}

const _host = HostInfo(
  os: HostOs.linux,
  machineArch: 'x86_64',
  archAliases: {'x86_64', 'x64', 'amd64'},
  hostType: 'fedora',
  versionId: '43',
);

const _singleTarget = '''
id: ivi-homescreen
type: app
supported_archs: [arm64]
supported_host_types: [ubuntu, fedora]
cross:
  provider: arm-gnu
  triple: aarch64-none-linux-gnu
  toolchain_version: 12.3.rel1
  image_url: https://example.com/os.img.xz
  cpu_flags: [-mcpu=cortex-a76]
''';

const _multiTarget = '''
id: ivi-homescreen
type: app
supported_host_types: [ubuntu]
cross:
  provider: arm-gnu
  toolchain_version: 12.3.rel1
  targets:
    rpi5:
      image_url: https://example.com/raspios.img.xz
      cpu_flags: [-mcpu=cortex-a76]
    rpi4:
      image_url: https://example.com/raspios.img.xz
      cpu_flags: [-mcpu=cortex-a72]
''';

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('emb_matrix_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  Future<int?> run(List<String> args) {
    final runner = CommandRunner<int>('emb', 'test')
      ..addCommand(MatrixCommand(logger: Logger(), host: _host));
    return runner.run(args);
  }

  File write(String name, String yaml) =>
      File(p.join(tmp.path, name))..writeAsStringSync(yaml);

  /// Render to a file (robust capture) and return its `include` list.
  Future<List<Map<String, dynamic>>> render(List<String> args) async {
    final outFile = p.join(tmp.path, 'matrix.json');
    final code = await run(['matrix', ...args, '-o', outFile]);
    expect(code, ExitCode.success.code);
    final decoded = jsonDecode(File(outFile).readAsStringSync()) as Map;
    return (decoded['include'] as List).cast<Map<String, dynamic>>();
  }

  test('usage error with no path argument', () async {
    expect(await run(['matrix']), ExitCode.usage.code);
  });

  test('a single-target manifest fans out over its supported hosts', () async {
    final f = write('pi5.emb.yaml', _singleTarget);
    final include = await render([f.path]);

    expect(include, hasLength(2)); // ubuntu + fedora
    final ubuntu = include.firstWhere((e) => e['host'] == 'ubuntu');
    expect(ubuntu['provider'], 'arm-gnu');
    expect(ubuntu['triple'], 'aarch64-none-linux-gnu');
    expect(ubuntu['target'], 'default');
    expect(ubuntu['runs_on'], 'ubuntu-latest');
    expect(ubuntu['args'], f.path); // no --target for a flat cross block
    expect(ubuntu['preflight'], 'tar xz rsync'); // arm-gnu preflight tools
    expect(ubuntu['sysroot_key'], isNotEmpty);
    expect(ubuntu['build_key'], isNotEmpty);

    final fedora = include.firstWhere((e) => e['host'] == 'fedora');
    expect(fedora['runs_on'], 'ubuntu-latest');
    expect(fedora['container'], 'fedora:41'); // no hosted fedora runner
  });

  test(
    'cpu-only variants share a sysroot_key but differ on build_key',
    () async {
      final f = write('rpi.emb.yaml', _multiTarget);
      final include = await render([f.path]);

      expect(include, hasLength(2)); // rpi5, rpi4 (one host: ubuntu)
      final rpi5 = include.firstWhere((e) => e['target'] == 'rpi5');
      final rpi4 = include.firstWhere((e) => e['target'] == 'rpi4');
      expect(rpi5['args'], '${f.path} --target rpi5');
      // Same image → shared extraction; only cpu tuning differs.
      expect(rpi5['sysroot_key'], rpi4['sysroot_key']);
      expect(rpi5['build_key'], isNot(rpi4['build_key']));
    },
  );

  test(
    '--host narrows to the intersection with supported_host_types',
    () async {
      final f = write('pi5.emb.yaml', _singleTarget);
      final include = await render([f.path, '--host', 'ubuntu']);
      expect(include, hasLength(1));
      expect(include.single['host'], 'ubuntu');
    },
  );

  test('--target emits only the named target', () async {
    final f = write('rpi.emb.yaml', _multiTarget);
    final include = await render([f.path, '--target', 'rpi4']);
    expect(include, hasLength(1));
    expect(include.single['target'], 'rpi4');
  });

  test('a directory globs *.emb.yaml', () async {
    write('pi5.emb.yaml', _singleTarget);
    write('rpi.emb.yaml', _multiTarget);
    final include = await render([tmp.path, '--host', 'ubuntu']);
    expect(include, hasLength(3)); // pi5 default + rpi5 + rpi4
  });

  test('a manifest without a cross: block is skipped', () async {
    final f = write('plain.emb.yaml', 'id: plain\ntype: app\n');
    final include = await render([f.path]);
    expect(include, isEmpty);
  });

  test(
    'a target that extends a board resolves instead of being skipped',
    () async {
      // A board library: the hardware (provider/triple) lives here, not in the
      // app manifest, which only `extends` it.
      final boards = Directory(p.join(tmp.path, 'boards'))..createSync();
      File(p.join(boards.path, 'raspberry-pi.emb.yaml')).writeAsStringSync('''
id: raspberry-pi
type: board
cross:
  provider: arm-gnu
  triple: aarch64-none-linux-gnu
  targets:
    rpi5-bookworm:
      toolchain_version: 12.3.rel1
      image_url: https://example.com/bookworm.img.xz
      cpu_flags: [-mcpu=cortex-a76]
''');
      final f = write('family.emb.yaml', '''
id: ivi-homescreen
type: app
supported_host_types: [ubuntu]
cross:
  targets:
    rpi5-bookworm:
      extends: rpi5-bookworm
''');

      final runner = CommandRunner<int>('emb', 'test')
        ..addCommand(
          MatrixCommand(
            logger: Logger(),
            host: _host,
            resolver: CrossProjectResolver(const ManifestLoader(), boards),
          ),
        );
      final outFile = p.join(tmp.path, 'matrix.json');
      expect(
        await runner.run(['matrix', f.path, '-o', outFile]),
        ExitCode.success.code,
      );
      final include =
          (jsonDecode(File(outFile).readAsStringSync()) as Map)['include']
              as List;

      expect(include, hasLength(1));
      final cell = include.single as Map<String, dynamic>;
      // Hardware came from the extended board, not the app manifest.
      expect(cell['target'], 'rpi5-bookworm');
      expect(cell['provider'], 'arm-gnu');
      expect(cell['triple'], 'aarch64-none-linux-gnu');
      expect(cell['args'], '${f.path} --target rpi5-bookworm');
    },
  );

  test('host_dev_packages is not emitted in the matrix cell', () async {
    final f = write('hostdev.emb.yaml', '''
id: ivi-homescreen
type: app
supported_host_types: [ubuntu]
cross:
  provider: arm-gnu
  triple: aarch64-none-linux-gnu
  toolchain_version: 12.3.rel1
  image_url: https://example.com/os.img.xz
  host_dev_packages: [libpugixml-dev, libssl-dev]
''');
    final include = await render([f.path, '--host', 'ubuntu']);

    expect(include, hasLength(1));
    expect(include.single.containsKey('host_dev_packages'), isFalse);
  });

  test('non-default build.app_path emits a deprecation warning', () async {
    final f = write('apppath.emb.yaml', '''
id: ivi-homescreen
type: app
supported_host_types: [ubuntu]
build:
  app_path: ../flutter_app
cross:
  provider: arm-gnu
  triple: aarch64-none-linux-gnu
  toolchain_version: 12.3.rel1
  image_url: https://example.com/os.img.xz
''');
    final logger = _CapturingLogger();
    final outFile = p.join(tmp.path, 'matrix_apppath.json');
    final runner = CommandRunner<int>('emb', 'test')
      ..addCommand(MatrixCommand(logger: logger, host: _host));
    expect(
      await runner.run(['matrix', f.path, '-o', outFile]),
      ExitCode.success.code,
    );
    expect(
      logger.warnings.toString(),
      contains('build.app_path is deprecated'),
    );
  });

  test(
    'build.app_path: . still emits a deprecation warning (key presence)',
    () async {
      final f = write('apppathdot.emb.yaml', '''
id: ivi-homescreen
type: app
supported_host_types: [ubuntu]
build:
  app_path: .
cross:
  provider: arm-gnu
  triple: aarch64-none-linux-gnu
  toolchain_version: 12.3.rel1
  image_url: https://example.com/os.img.xz
''');
      final logger = _CapturingLogger();
      final outFile = p.join(tmp.path, 'matrix_apppathdot.json');
      final runner = CommandRunner<int>('emb', 'test')
        ..addCommand(MatrixCommand(logger: logger, host: _host));
      expect(
        await runner.run(['matrix', f.path, '-o', outFile]),
        ExitCode.success.code,
      );
      expect(
        logger.warnings.toString(),
        contains('build.app_path is deprecated'),
      );
    },
  );

  test(
    'build block without app_path key does not emit a deprecation warning',
    () async {
      final f = write('buildnoapppath.emb.yaml', '''
id: ivi-homescreen
type: app
supported_host_types: [ubuntu]
build:
  archs: [arm64]
cross:
  provider: arm-gnu
  triple: aarch64-none-linux-gnu
  toolchain_version: 12.3.rel1
  image_url: https://example.com/os.img.xz
''');
      final logger = _CapturingLogger();
      final outFile = p.join(tmp.path, 'matrix_buildnoapp.json');
      final runner = CommandRunner<int>('emb', 'test')
        ..addCommand(MatrixCommand(logger: logger, host: _host));
      expect(
        await runner.run(['matrix', f.path, '-o', outFile]),
        ExitCode.success.code,
      );
      expect(logger.warnings.toString(), isEmpty);
    },
  );

  // `extends: 'source#<target>'` names a target inside the embedder's repo.
  // The matrix downloads nothing unless asked, so the cell exists when the
  // checkout does, or with --fetch.
  group("extends: 'source#<target>'", () {
    late _CapturingLogger logger;
    late Directory origin;

    /// The cells, and the exit code they came with.
    Future<List<Map<String, dynamic>>> cells(List<String> args) async {
      final outFile = p.join(tmp.path, 'matrix.json');
      final runner = CommandRunner<int>('emb', 'test')
        ..addCommand(MatrixCommand(logger: logger, host: _host));
      expect(
        await runner.run(['matrix', ...args, '-o', outFile]),
        ExitCode.success.code,
      );
      final decoded = jsonDecode(File(outFile).readAsStringSync()) as Map;
      return (decoded['include'] as List).cast<Map<String, dynamic>>();
    }

    /// An embedder project with one board target, `rpi`.
    void writeEmbedder(Directory dir) {
      Directory(p.join(dir.path, '.emb')).createSync(recursive: true);
      File(p.join(dir.path, '.emb', 'rpi.emb.yaml')).writeAsStringSync(
        'id: embedder\ncross:\n  targets:\n    rpi:\n'
        '      provider: arm-gnu\n'
        '      triple: aarch64-none-linux-gnu\n'
        '      toolchain_version: 12.3.rel1\n'
        '      image_url: https://example.com/os.img.xz\n',
      );
    }

    /// The same project as a git repository to clone from.
    Future<void> makeOrigin() async {
      origin = Directory(p.join(tmp.path, 'origin', 'embedder'));
      writeEmbedder(origin);
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

    /// One target that extends into the source, and one that stands alone.
    File manifest(String uri) => write(
      'app.emb.yaml',
      'id: app\ntype: app\nworkspace: ws\nsupported_host_types: [ubuntu]\n'
          'cross:\n'
          '  source: { uri: $uri }\n'
          '  targets:\n'
          "    pi: { extends: 'source#rpi' }\n"
          '    plain:\n'
          '      provider: arm-gnu\n'
          '      triple: aarch64-none-linux-gnu\n'
          '      toolchain_version: 12.3.rel1\n'
          '      image_url: https://example.com/other.img.xz\n',
    );

    Directory checkout([String ws = 'ws']) =>
        Directory(p.join(tmp.path, ws, 'app', 'embedder'));

    setUp(() => logger = _CapturingLogger());

    test('is skipped, and nothing is cloned, without the checkout', () async {
      await makeOrigin();
      final include = await cells([manifest(origin.path).path]);
      expect(include.map((c) => c['target']), ['plain']);
      expect(checkout().existsSync(), isFalse);
      final warned = logger.warnings.toString();
      expect(warned, contains('#pi'));
      expect(warned, contains('--fetch'));
    });

    test('resolves against a checkout the workspace has', () async {
      writeEmbedder(checkout());
      final include = await cells([
        manifest('https://invalid.example/embedder.git').path,
      ]);
      expect(include.map((c) => c['target']), ['pi', 'plain']);
      final pi = include.first;
      expect(pi['provider'], 'arm-gnu');
      expect(pi['triple'], 'aarch64-none-linux-gnu');
      expect(pi['sysroot_key'], isNotEmpty);
      expect(logger.warnings.toString(), isEmpty);
    });

    test('--fetch clones the source and emits the cell', () async {
      await makeOrigin();
      final include = await cells([manifest(origin.path).path, '--fetch']);
      expect(include.map((c) => c['target']), ['pi', 'plain']);
      expect(checkout().existsSync(), isTrue);
    });

    test('--fetch that cannot clone skips the target and says why', () async {
      final f = manifest(p.join(tmp.path, 'no-such-repo'));
      final include = await cells([f.path, '--fetch']);
      expect(include.map((c) => c['target']), ['plain']);
      expect(logger.warnings.toString(), contains('could not be fetched'));
    });

    test('-w outranks the workspace the manifest declares', () async {
      writeEmbedder(checkout('other'));
      final include = await cells([
        manifest('https://invalid.example/embedder.git').path,
        '-w',
        p.join(tmp.path, 'other'),
      ]);
      expect(include.map((c) => c['target']), ['pi', 'plain']);
    });

    test('with no cross.source it is skipped with that reason', () async {
      final f = write(
        'app.emb.yaml',
        'id: app\ntype: app\nsupported_host_types: [ubuntu]\ncross:\n'
            '  targets:\n'
            "    pi: { extends: 'source#rpi' }\n",
      );
      expect(await cells([f.path]), isEmpty);
      expect(logger.warnings.toString(), contains('declares none'));
    });
  });

  // A `.emb/` project is read as `emb cross` reads it: the base merged under
  // each board file, one cell per board target, and no cell for the base.
  group('a .emb/ project', () {
    late Directory project;

    setUp(() {
      project = Directory(p.join(tmp.path, 'proj'));
      final emb = Directory(p.join(project.path, '.emb'))
        ..createSync(recursive: true);
      File(p.join(emb.path, 'base.emb.yaml')).writeAsStringSync(
        'id: proj\nsupported_host_types: [ubuntu, fedora]\ncross:\n'
        '  provider: arm-gnu\n  toolchain_version: 12.3.rel1\n',
      );
      File(p.join(emb.path, 'rpi.emb.yaml')).writeAsStringSync(
        'id: rpi\ncross:\n  targets:\n'
        '    rpi5:\n'
        '      triple: aarch64-none-linux-gnu\n'
        '      image_url: https://example.com/os.img.xz\n'
        '      cpu_flags: [-mcpu=cortex-a76]\n'
        '    rpi4:\n'
        '      triple: aarch64-none-linux-gnu\n'
        '      image_url: https://example.com/os.img.xz\n'
        '      cpu_flags: [-mcpu=cortex-a72]\n',
      );
    });

    test('yields its board targets with the base merged under them', () async {
      final include = await render([project.path, '--host', 'ubuntu']);
      expect(
        include.map((c) => c['target']),
        unorderedEquals(['rpi5', 'rpi4']),
      );
      final rpi5 = include.firstWhere((c) => c['target'] == 'rpi5');
      // The provider and toolchain come from base.emb.yaml.
      expect(rpi5['provider'], 'arm-gnu');
      expect(rpi5['triple'], 'aarch64-none-linux-gnu');
      expect(rpi5['args'], '${project.path} --target rpi5');
      expect(rpi5['manifest'], p.join(project.path, '.emb', 'rpi.emb.yaml'));
      expect(rpi5['id'], 'proj');
    });

    test("a board file naming no hosts takes the base's", () async {
      final include = await render([project.path]);
      expect(
        include.where((c) => c['target'] == 'rpi5').map((c) => c['host']),
        unorderedEquals(['ubuntu', 'fedora']),
      );
    });

    test('the .emb directory itself is the same project', () async {
      final viaDir = await render([project.path, '--host', 'ubuntu']);
      final viaEmb = await render([
        p.join(project.path, '.emb'),
        '--host',
        'ubuntu',
      ]);
      expect(viaEmb, viaDir);
    });

    test('--target picks one board target', () async {
      final include = await render([
        project.path,
        '--host',
        'ubuntu',
        '--target',
        'rpi4',
      ]);
      expect(include.single['target'], 'rpi4');
    });

    test('beside flat manifests, each is rendered once', () async {
      final f = write('pi5.emb.yaml', _singleTarget);
      final include = await render([
        project.path,
        f.path,
        project.path,
        '--host',
        'ubuntu',
      ]);
      expect(
        include.map((c) => c['target']),
        unorderedEquals(['rpi5', 'rpi4', 'default']),
      );
    });
  });
}
