import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:emb_cli/src/commands/cross_command.dart';
import 'package:emb_cli/src/cross/cross_keys.dart';
import 'package:emb_cli/src/cross/cross_target.dart';
import 'package:emb_cli/src/cross/dockerfile_emitter.dart';
import 'package:emb_cli/src/cross/process_runner.dart';
import 'package:emb_cli/src/host/host_info.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Captures `info` lines so a `--json` envelope can be parsed back.
class _CaptureLogger extends Logger {
  final StringBuffer buffer = StringBuffer();
  @override
  void info(String? message, {LogStyle? style}) => buffer.writeln(message);
}

const _host = HostInfo(
  os: HostOs.linux,
  machineArch: 'x86_64',
  archAliases: {'x86_64', 'x64', 'amd64'},
  hostType: 'fedora',
  versionId: '43',
);

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('emb_xcmd_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  Future<int?> run(List<String> args) {
    final runner = CommandRunner<int>('emb', 'test')
      ..addCommand(CrossCommand(logger: Logger(), host: _host));
    return runner.run(args);
  }

  Future<(int?, Map<String, dynamic>)> runJson(List<String> args) async {
    final logger = _CaptureLogger();
    final runner = CommandRunner<int>('emb', 'test')
      ..addCommand(CrossCommand(logger: logger, host: _host));
    final code = await runner.run(args);
    return (code, jsonDecode(logger.buffer.toString()) as Map<String, dynamic>);
  }

  Directory pkgWith(String name, String embYaml) {
    final pkg = Directory(p.join(tmp.path, name))..createSync();
    File(p.join(pkg.path, 'emb.yaml')).writeAsStringSync(embYaml);
    return pkg;
  }

  test('usage error with no package argument', () async {
    expect(await run(['cross']), ExitCode.usage.code);
  });

  test('usage error when the dir has no manifest', () async {
    expect(await run(['cross', tmp.path]), ExitCode.usage.code);
  });

  test('usage error when the manifest has no cross: block', () async {
    final pkg = pkgWith('a', 'id: a\ntype: app\n');
    expect(await run(['cross', pkg.path]), ExitCode.usage.code);
  });

  test('usage error on an unknown provider token (G-03)', () async {
    final pkg = pkgWith('b', 'id: b\ntype: app\ncross:\n  provider: nope\n');
    expect(await run(['cross', pkg.path]), ExitCode.usage.code);
  });

  test('--publish without --image fails fast before any resolve', () async {
    final pkg = pkgWith(
      'pub',
      'id: pub\ntype: app\ncross:\n  provider: arm-gnu\n'
          '  toolchain_version: 12.3.rel1\n  image_url: https://x/y.img.xz\n',
    );
    // No --image, so it must error without downloading anything.
    expect(await run(['cross', pkg.path, '--publish']), ExitCode.usage.code);
  });

  test('a malformed --define fails fast before any resolve', () async {
    final pkg = pkgWith(
      'defbad',
      'id: defbad\ntype: app\ncross:\n  provider: arm-gnu\n'
          '  toolchain_version: 12.3.rel1\n  image_url: https://x/y.img.xz\n',
    );
    expect(
      await run(['cross', pkg.path, '-D', 'NO_EQUALS']),
      ExitCode.usage.code,
    );
  });

  test('--define overrides plan cleanly through --dry-run', () async {
    final pkg = pkgWith(
      'defok',
      'id: defok\ntype: app\ncross:\n  provider: arm-gnu\n'
          '  toolchain_version: 12.3.rel1\n  image_url: https://x/y.img.xz\n'
          '  defines:\n    ENABLE_SENTRY: OFF\n'
          '  backends:\n    wayland-egl:\n'
          '      BUILD_BACKEND_WAYLAND_EGL: ON\n'
          '      ENABLE_SENTRY: OFF\n',
    );
    expect(
      await run(['cross', '--dry-run', pkg.path, '-D', 'ENABLE_SENTRY=ON']),
      ExitCode.success.code,
    );
  });

  test('--define overrides plan cleanly for a meson embedder', () async {
    final pkg = pkgWith(
      'defmeson',
      'id: defmeson\ntype: app\ncross:\n  provider: arm-gnu\n'
          '  toolchain_version: 12.3.rel1\n  image_url: https://x/y.img.xz\n'
          '  generator: meson\n'
          '  defines:\n    backend: drm-gl\n',
    );
    expect(
      await run(['cross', '--dry-run', pkg.path, '-D', 'backend=wayland']),
      ExitCode.success.code,
    );
  });

  test('the glued -DKEY=VALUE form is accepted', () async {
    final pkg = pkgWith(
      'defglue',
      'id: defglue\ntype: app\ncross:\n  provider: arm-gnu\n'
          '  toolchain_version: 12.3.rel1\n  image_url: https://x/y.img.xz\n',
    );
    expect(
      await run(['cross', '--dry-run', pkg.path, '-DENABLE_SENTRY=ON']),
      ExitCode.success.code,
    );
  });

  test('an empty --define value is accepted (CMake unset-style)', () async {
    final pkg = pkgWith(
      'defempty',
      'id: defempty\ntype: app\ncross:\n  provider: arm-gnu\n'
          '  toolchain_version: 12.3.rel1\n  image_url: https://x/y.img.xz\n',
    );
    expect(
      await run(['cross', '--dry-run', pkg.path, '-D', 'ENABLE_SENTRY=']),
      ExitCode.success.code,
    );
  });

  test('a value containing = survives (split on first = only)', () async {
    final pkg = pkgWith(
      'defeq',
      'id: defeq\ntype: app\ncross:\n  provider: arm-gnu\n'
          '  toolchain_version: 12.3.rel1\n  image_url: https://x/y.img.xz\n',
    );
    expect(
      await run([
        'cross',
        '--dry-run',
        pkg.path,
        '-D',
        'CMAKE_CXX_FLAGS=-DFOO=1',
      ]),
      ExitCode.success.code,
    );
  });

  test('repeated --define entries plan cleanly (last wins)', () async {
    final pkg = pkgWith(
      'defrepeat',
      'id: defrepeat\ntype: app\ncross:\n  provider: arm-gnu\n'
          '  toolchain_version: 12.3.rel1\n  image_url: https://x/y.img.xz\n',
    );
    expect(
      await run([
        'cross',
        '--dry-run',
        pkg.path,
        '-D',
        'ENABLE_SENTRY=OFF',
        '-D',
        'ENABLE_SENTRY=ON',
      ]),
      ExitCode.success.code,
    );
  });

  test('publish skip probe uses the resolved triple', () async {
    // A manifest that omits `triple` resolves to the arm-gnu default; the
    // skip-on-exists probe must use that resolved triple, not an empty one, or
    // it would never match the published tag and would re-resolve every run.
    const cross = {
      'provider': 'arm-gnu',
      'toolchain_version': '12.3.rel1',
      'image_url': 'https://x/y.img.xz',
    };
    final pkg = pkgWith(
      'skip',
      'id: skip\ntype: app\ncross:\n  provider: arm-gnu\n'
          '  toolchain_version: 12.3.rel1\n  image_url: https://x/y.img.xz\n',
    );
    final target = CrossTarget.fromMap(cross);
    final publishedTag = ToolchainImage.imageTag(
      triple: 'aarch64-none-linux-gnu',
      sysrootKey: sysrootKey(target),
      toolchainVersion: target.toolchainVersion,
      hostDevPackages: target.hostDevPackages,
    );
    const image = 'reg.example/x';

    final calls = <String>[];
    Future<RunResult> runner(
      String exe,
      List<String> args, {
      String? workingDirectory,
      Map<String, String>? environment,
      bool includeParentEnvironment = true,
      bool runInShell = false,
      ProcessOutputMode output = ProcessOutputMode.capture,
      String? label,
    }) async {
      calls.add('$exe ${args.join(' ')}');
      // docker is present, skopeo is not (so the probe is `manifest inspect`).
      if (args.length == 1 && args.first == '--version') {
        return RunResult(exe == 'docker' ? 0 : 1, '', '');
      }
      // "Published" only for the correct, resolved-triple ref.
      if (args.length >= 2 && args[0] == 'manifest' && args[1] == 'inspect') {
        return RunResult(args.last == '$image:$publishedTag' ? 0 : 1, '', '');
      }
      return const RunResult(1, '', '');
    }

    final crossRunner = CommandRunner<int>('emb', 'test')
      ..addCommand(
        CrossCommand(logger: Logger(), host: _host, processRunner: runner),
      );
    final code = await crossRunner.run([
      'cross',
      pkg.path,
      '--publish',
      '--image',
      image,
    ]);

    // Skipped (no resolve/download), and the probe used the resolved-triple tag.
    expect(code, ExitCode.success.code);
    expect(calls, contains('docker manifest inspect $image:$publishedTag'));
  });

  test('--dry-run reports the backends matrix', () async {
    final pkg = pkgWith(
      'be',
      'id: be\ntype: app\ncross:\n  provider: arm-gnu\n'
          '  toolchain_version: 12.3.rel1\n  image_url: https://x/y.img.xz\n'
          '  backends:\n    wayland-egl:\n'
          '      BUILD_BACKEND_WAYLAND_EGL: ON\n',
    );
    expect(await run(['cross', '--dry-run', pkg.path]), ExitCode.success.code);
  });

  test('--dry-run plans a manifest file', () async {
    final pkg = Directory(p.join(tmp.path, 'c'))..createSync();
    final f = File(p.join(pkg.path, 'pi.emb.yaml'))
      ..writeAsStringSync(
        'id: pi\ntype: app\ncross:\n  provider: arm-gnu\n'
        '  toolchain_version: 12.3.rel1\n  image_url: https://x/y.img.xz\n',
      );
    expect(await run(['cross', '--dry-run', f.path]), ExitCode.success.code);
  });

  test('--json emits the plan envelope (implies --dry-run)', () async {
    final pkg = pkgWith(
      'j',
      'id: j\ntype: app\ncross:\n  provider: arm-gnu\n'
          '  triple: aarch64-none-linux-gnu\n'
          '  toolchain_version: 12.3.rel1\n  image_url: https://x/y.img.xz\n'
          '  cpu_flags: [-mcpu=cortex-a76]\n'
          '  backends:\n    wayland-egl:\n'
          '      BUILD_BACKEND_WAYLAND_EGL: ON\n',
    );
    final (code, json) = await runJson(['cross', '--json', pkg.path]);
    expect(code, ExitCode.success.code);
    expect(json['schema'], 1);
    expect(json['command'], 'cross');
    expect(json['ok'], true);
    final data = json['data'] as Map<String, dynamic>;
    expect(data['provider'], 'arm-gnu');
    expect(data['triple'], 'aarch64-none-linux-gnu');
    expect(data['cpuFlags'], ['-mcpu=cortex-a76']);
    expect(data['backends'], ['wayland-egl']);
    expect((data['sysroot'] as Map)['source'], 'image');
  });

  // A manifest whose cross: block defines several platforms via cross.targets.
  String targetsManifest() =>
      'id: multi\ntype: app\ncross:\n  provider: arm-gnu\n'
      '  toolchain_version: 12.3.rel1\n'
      '  targets:\n'
      '    rpi5:        { image_url: https://x/raspios.img.xz, '
      'cpu_flags: [-mcpu=cortex-a76] }\n'
      '    rpi4:        { image_url: https://x/raspios.img.xz, '
      'cpu_flags: [-mcpu=cortex-a72] }\n'
      '    radxa-zero3: { image_url: https://x/radxa.img.xz, '
      'cpu_flags: [-mcpu=cortex-a55] }\n';

  test('--list-targets prints the platforms and exits', () async {
    final pkg = pkgWith('mt', targetsManifest());
    expect(
      await run(['cross', '--list-targets', pkg.path]),
      ExitCode.success.code,
    );
  });

  test('a targets manifest defaults to the native local build', () async {
    final pkg = pkgWith('mt2', targetsManifest());
    // No --target → local (native host build), which plans successfully.
    expect(await run(['cross', '--dry-run', pkg.path]), ExitCode.success.code);
  });

  test('--target local / host select the native build', () async {
    final pkg = pkgWith('mt2b', targetsManifest());
    for (final t in ['local', 'host']) {
      expect(
        await run(['cross', '--dry-run', '--target', t, pkg.path]),
        ExitCode.success.code,
        reason: '--target $t failed',
      );
    }
  });

  test('--target local works on a single-block manifest too', () async {
    final pkg = pkgWith(
      'sb',
      'id: sb\ntype: app\ncross:\n  provider: arm-gnu\n'
          '  toolchain_version: 12.3.rel1\n  image_url: https://x/y.img.xz\n',
    );
    expect(
      await run(['cross', '--dry-run', '--target', 'local', pkg.path]),
      ExitCode.success.code,
    );
  });

  test('--target selects a platform and plans it (--dry-run)', () async {
    final pkg = pkgWith('mt3', targetsManifest());
    expect(
      await run(['cross', '--dry-run', '--target', 'rpi5', pkg.path]),
      ExitCode.success.code,
    );
  });

  test('an unknown --target is a usage error', () async {
    final pkg = pkgWith('mt4', targetsManifest());
    expect(
      await run(['cross', '--dry-run', '--target', 'nope', pkg.path]),
      ExitCode.usage.code,
    );
  });

  test('--target on a single-block manifest is a usage error', () async {
    final pkg = pkgWith(
      'single',
      'id: single\ntype: app\ncross:\n  provider: arm-gnu\n'
          '  toolchain_version: 12.3.rel1\n  image_url: https://x/y.img.xz\n',
    );
    expect(
      await run(['cross', '--dry-run', '--target', 'rpi5', pkg.path]),
      ExitCode.usage.code,
    );
  });

  // A project whose manifests live under a `.emb/` directory: a shared base, a
  // flat per-board file, and a family file grouping image-sharing variants.
  Directory embProject(String name) {
    final emb = Directory(p.join(tmp.path, name, '.emb'))
      ..createSync(recursive: true);
    File(p.join(emb.path, 'base.emb.yaml')).writeAsStringSync(
      'id: ivi\ncross:\n  provider: arm-gnu\n'
      '  toolchain_version: 12.3.rel1\n',
    );
    File(p.join(emb.path, 'imx93.emb.yaml')).writeAsStringSync(
      'platform: {name: imx93-evk, description: NXP i.MX93}\n'
      'cross:\n  image_url: https://x/imx93.img.xz\n',
    );
    File(p.join(emb.path, 'rpi.emb.yaml')).writeAsStringSync(
      'platform: {name: raspberry-pi}\n'
      'cross:\n  targets:\n'
      '    rpi5: { image_url: https://x/raspios.img.xz, '
      'cpu_flags: [-mcpu=cortex-a76] }\n'
      '    rpi4: { image_url: https://x/raspios.img.xz, '
      'cpu_flags: [-mcpu=cortex-a72] }\n',
    );
    return Directory(p.join(tmp.path, name));
  }

  test('.emb/ project lists the union of flat + family targets', () async {
    final proj = embProject('p1');
    expect(
      await run(['cross', '--list-targets', proj.path]),
      ExitCode.success.code,
    );
  });

  test('.emb/ flat-file target inherits the shared base + plans', () async {
    final proj = embProject('p2');
    // imx93-evk only sets image_url; provider comes from base.emb.yaml.
    expect(
      await run(['cross', '--dry-run', '--target', 'imx93-evk', proj.path]),
      ExitCode.success.code,
    );
  });

  test('.emb/ family variant inherits the base provider + plans', () async {
    final proj = embProject('p3');
    expect(
      await run(['cross', '--dry-run', '--target', 'rpi5', proj.path]),
      ExitCode.success.code,
    );
  });

  test('.emb/ with no --target defaults to the native local build', () async {
    final proj = embProject('p4');
    expect(await run(['cross', '--dry-run', proj.path]), ExitCode.success.code);
  });

  test('.emb/ duplicate target names across files is a usage error', () async {
    final emb = Directory(p.join(tmp.path, 'dup', '.emb'))
      ..createSync(recursive: true);
    for (final f in ['a', 'b']) {
      File(p.join(emb.path, '$f.emb.yaml')).writeAsStringSync(
        'platform: {name: board}\n'
        'cross: {provider: arm-gnu, toolchain_version: 12.3.rel1}\n',
      );
    }
    expect(
      await run(['cross', '--list-targets', p.join(tmp.path, 'dup')]),
      ExitCode.usage.code,
    );
  });

  test(
    '--backend with an unknown name is a usage error (no download)',
    () async {
      final pkg = pkgWith(
        'bk',
        'id: bk\ntype: app\ncross:\n  provider: arm-gnu\n'
            '  toolchain_version: 12.3.rel1\n  image_url: https://x/y.img.xz\n'
            '  backends:\n    drm-kms-egl:\n'
            '      BUILD_BACKEND_DRM_KMS_EGL: ON\n',
      );
      // 'wayland-egl' isn't in the manifest → fail fast before resolving.
      final code = await run([
        'cross',
        '--build',
        '--backend',
        'wayland-egl',
        pkg.path,
      ]);
      expect(code, ExitCode.usage.code);
    },
  );

  // The cross config staged here must match the manifest so the keys align.
  final cleanTarget = CrossTarget.fromMap(const {
    'provider': 'arm-gnu',
    'toolchain_version': '12.3.rel1',
    'image_url': 'https://x/y.img.xz',
  });

  test('--clean removes build + overlay dirs, keeps the toolchain', () async {
    final pkg = pkgWith(
      'cl',
      'id: cl\ntype: app\ncross:\n  provider: arm-gnu\n'
          '  toolchain_version: 12.3.rel1\n  image_url: https://x/y.img.xz\n',
    );
    const triple = 'aarch64-none-linux-gnu';
    final sk = sysrootKey(cleanTarget);
    final bk = buildKey(cleanTarget);
    final root = p.join(tmp.path, '.config', 'flutter_workspace');
    for (final d in [
      'cross-$triple-$sk',
      'cross-build-$triple-$bk',
      'overlay-$triple',
    ]) {
      Directory(p.join(root, d)).createSync(recursive: true);
    }

    final code = await run(['cross', '-w', tmp.path, '--clean', pkg.path]);
    expect(code, ExitCode.success.code);
    expect(
      Directory(p.join(root, 'cross-build-$triple-$bk')).existsSync(),
      isFalse,
    );
    expect(Directory(p.join(root, 'overlay-$triple')).existsSync(), isFalse);
    // The expensive toolchain/sysroot dir is preserved by plain --clean.
    expect(Directory(p.join(root, 'cross-$triple-$sk')).existsSync(), isTrue);
  });

  test('--clean-all also removes the toolchain + sysroot dir', () async {
    final pkg = pkgWith(
      'ca',
      'id: ca\ntype: app\ncross:\n  provider: arm-gnu\n'
          '  toolchain_version: 12.3.rel1\n  image_url: https://x/y.img.xz\n',
    );
    const triple = 'aarch64-none-linux-gnu';
    final sk = sysrootKey(cleanTarget);
    final root = p.join(tmp.path, '.config', 'flutter_workspace');
    Directory(p.join(root, 'cross-$triple-$sk')).createSync(recursive: true);

    final code = await run(['cross', '-w', tmp.path, '--clean-all', pkg.path]);
    expect(code, ExitCode.success.code);
    expect(Directory(p.join(root, 'cross-$triple-$sk')).existsSync(), isFalse);
  });

  test('--dry-run plans the all-backends example (local)', () async {
    final example = p.join('examples', 'cross', 'all-backends.emb.yaml');
    expect(
      await run(['cross', '--dry-run', '--target', 'local', example]),
      ExitCode.success.code,
    );
  });

  test('--dry-run plans every target of the multi-platform example', () async {
    final example = p.join('examples', 'cross', 'raspberry-pi-family.emb.yaml');
    for (final t in [
      'rpi5-bookworm',
      'rpi5-trixie',
      'rpi4-bookworm',
      'rpi4-trixie',
      'rpi-zero-2w-bookworm',
      'rpi-zero-2w-trixie',
    ]) {
      final code = await run(['cross', '--dry-run', '--target', t, example]);
      expect(code, ExitCode.success.code, reason: '$t dry-run failed');
    }
  });

  test(
    '--dry-run plans the app-extends example (app → project → board)',
    () async {
      final app = p.join('examples', 'cross', 'app-extends.emb.yaml');
      final code = await run([
        'cross',
        '--dry-run',
        '--target',
        'rpi5-bookworm',
        app,
      ]);
      expect(code, ExitCode.success.code);
    },
  );

  // Every shipped example must parse -> dispatch -> plan with no side effects:
  // this validates all of the listed use cases hermetically.
  test('--dry-run plans every example manifest', () async {
    const examples = [
      'pi5',
      'unoq',
      'radxa_zero3',
      'beagleplay',
      'nitrogen8mm',
      'agl_sdk_local',
      'agl_sdk_url',
    ];
    for (final name in examples) {
      final code = await run([
        'cross',
        '--dry-run',
        p.join('examples', 'cross', '$name.emb.yaml'),
      ]);
      expect(code, ExitCode.success.code, reason: '$name dry-run failed');
    }
  });
}
