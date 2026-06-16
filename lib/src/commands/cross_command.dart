import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:emb_cli/src/cross/cross_arch.dart';
import 'package:emb_cli/src/cross/cross_builder.dart';
import 'package:emb_cli/src/cross/cross_keys.dart';
import 'package:emb_cli/src/cross/cross_profile.dart';
import 'package:emb_cli/src/cross/cross_provider.dart';
import 'package:emb_cli/src/cross/cross_target.dart';
import 'package:emb_cli/src/cross/deb_packager.dart';
import 'package:emb_cli/src/cross/local_cross_provider.dart';
import 'package:emb_cli/src/cross/overlay_builder.dart';
import 'package:emb_cli/src/host/host_info.dart';
import 'package:emb_cli/src/manifest/manifest_loader.dart';
import 'package:emb_cli/src/workspace/workspace.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:path/path.dart' as p;

/// {@template cross_command}
/// `emb cross <package>` — resolve a target manifest's `cross:` block into a
/// [CrossProfile] (toolchain + sysroot(s) + emitted build files), and with
/// `--prepare` also build its augment libraries into the overlay.
///
/// This is the consumer that turns the cross layer into a usable command; the
/// per-backend configure/build hangs off the resolved profile.
/// {@endtemplate}
class CrossCommand extends Command<int> {
  /// {@macro cross_command}
  CrossCommand({
    required Logger logger,
    HostInfo? host,
    ManifestLoader loader = const ManifestLoader(),
  }) : _logger = logger,
       _host = host,
       _loader = loader {
    argParser
      ..addOption(
        'workspace',
        abbr: 'w',
        help: r'Workspace root (defaults to $FLUTTER_WORKSPACE or cwd).',
      )
      ..addFlag(
        'prepare',
        help: 'Also build augment libraries into the overlay.',
        negatable: false,
      )
      ..addFlag(
        'dry-run',
        help:
            'Report the resolution plan (provider, toolchain, sysroot, '
            'preflight, local inputs) without downloading, mounting, or ssh.',
        negatable: false,
      )
      ..addFlag(
        'build',
        help:
            'Configure + build the embedder under the resolved profile, one '
            'build per cross.backends entry.',
        negatable: false,
      )
      ..addOption(
        'target',
        abbr: 't',
        help:
            'Select a platform from cross.targets (e.g. rpi5, radxa-zero3). '
            'Its fields override the shared cross: block.',
      )
      ..addFlag(
        'list-targets',
        help: 'List the platforms defined under cross.targets, then exit.',
        negatable: false,
      )
      ..addMultiOption(
        'backend',
        help:
            'Build only the named cross.backends entries. Repeatable; '
            'defaults to every backend in the manifest.',
      )
      ..addFlag(
        'deb',
        help:
            'After building, package each backend binary into a .deb '
            '(root-free; Depends derived from the binary + sysroot).',
        negatable: false,
      )
      ..addFlag(
        'clean',
        help:
            'Remove this target build + overlay dirs (keeps the toolchain '
            'and sysroot), then exit.',
        negatable: false,
      )
      ..addFlag(
        'clean-all',
        help:
            'Also remove the downloaded/extracted toolchain + sysroot (and '
            'apt/deb caches) for this target, then exit.',
        negatable: false,
      );
  }

  final Logger _logger;
  final HostInfo? _host;
  final ManifestLoader _loader;

  @override
  String get name => 'cross';

  @override
  String get description =>
      'Resolve a manifest cross: block into a toolchain + sysroot profile.';

  @override
  Future<int> run() async {
    final args = argResults!;
    if (args.rest.isEmpty) {
      _logger.err('Usage: emb cross <package-dir|manifest.yaml> [--dry-run]');
      return ExitCode.usage.code;
    }

    // Accept either a package directory (with emb.yaml) or an explicit manifest
    // file (e.g. examples/cross/pi5.emb.yaml).
    final inputPath = args.rest.first;
    final manifest =
        FileSystemEntity.typeSync(inputPath) == FileSystemEntityType.file
        ? _loader.loadManifestFile(File(inputPath))
        : _loader.loadPackageDir(Directory(inputPath));
    if (manifest == null) {
      _logger.err('No emb manifest at $inputPath.');
      return ExitCode.usage.code;
    }
    final crossMap = manifest.raw['cross'];
    if (crossMap is! Map) {
      _logger.err('${manifest.id} has no cross: block.');
      return ExitCode.usage.code;
    }
    final targets = crossMap['targets'];
    final hasTargets = targets is Map && targets.isNotEmpty;

    // --list-targets: print the platforms this manifest defines, exit.
    if (args['list-targets'] == true) {
      final names = hasTargets ? targets.keys.join(', ') : '(none)';
      _logger.info('Targets: $names  (plus the built-in: local)');
      return ExitCode.success.code;
    }

    // Resolve the effective target. `local`/`host` is the native host build;
    // it's the default when the manifest defines targets but none is chosen.
    final targetArg = args['target'] as String?;
    final effectiveTarget = targetArg ?? (hasTargets ? 'local' : null);
    final isNative = effectiveTarget == 'local' || effectiveTarget == 'host';

    final Map<dynamic, dynamic>? selected;
    if (isNative) {
      // Native uses the shared fields (backends / defines / package); the
      // cross-only fields (image_url, toolchain, cpu_flags) don't apply.
      selected = {
        for (final e in crossMap.entries)
          if (e.key != 'targets') e.key: e.value,
      };
    } else {
      selected = _selectCrossMap(crossMap, effectiveTarget);
    }
    if (selected == null) return ExitCode.usage.code;

    final CrossTarget target;
    try {
      target = CrossTarget.fromMap(selected);
      // fromMap throws ArgumentError on an unknown provider token.
      // ignore: avoid_catching_errors
    } on ArgumentError catch (e) {
      _logger.err('Invalid cross: block — ${e.message}');
      return ExitCode.usage.code;
    }

    // Validate --backend against the manifest up front, before any download.
    final selectedBackends = args['backend'] as List<String>;
    final unknownBackends = selectedBackends.where(
      (b) => !target.backends.containsKey(b),
    );
    if (unknownBackends.isNotEmpty) {
      _logger.err(
        'Unknown backend(s): ${unknownBackends.join(", ")}. '
        'Available: ${target.backends.keys.join(", ")}',
      );
      return ExitCode.usage.code;
    }

    final host = _host ?? HostInfo.detect();
    final workspace = Workspace.resolve(override: args['workspace'] as String?);
    final provider = isNative
        ? LocalCrossProvider(host)
        : CrossProvider.forTarget(target, workspace: workspace, host: host);

    // --clean / --clean-all: remove working dirs and exit (no download).
    if (args['clean'] == true || args['clean-all'] == true) {
      return _clean(
        provider,
        target,
        workspace,
        all: args['clean-all'] == true,
      );
    }

    // --dry-run: report the plan without any download / mount / ssh side
    // effects, so every target validates on any host.
    if (args['dry-run'] == true) {
      if (isNative) {
        final be = target.backends.isEmpty
            ? '(plain)'
            : target.backends.keys.join(', ');
        _logger
          ..info(styleBold.wrap('Cross plan (local)'))
          ..info('  native build  : ${host.machineArch} (host toolchain)')
          ..info('  backends      : $be');
        return ExitCode.success.code;
      }
      await _plan(provider, target, host);
      return ExitCode.success.code;
    }

    // Provider-declared preflight (tar/xz/rsync for arm-gnu, etc.).
    final missing = await _missingTools(provider.preflightTools);
    if (missing.isNotEmpty) {
      _logger.err(
        'Missing host tools for ${provider.name}: ${missing.join(", ")}',
      );
      return ExitCode.unavailable.code;
    }

    final progress = _logger.progress(
      'Resolving ${provider.name} cross profile',
    );
    final result = await provider.resolve();
    if (!result.ok) {
      progress.fail(result.message ?? 'resolve failed');
      return result.status == CrossResolveStatus.unavailable
          ? ExitCode.unavailable.code
          : ExitCode.software.code;
    }
    final profile = result.profile!;
    progress.complete('Resolved ${provider.name}');
    _report(profile);

    if (args['prepare'] == true && target.augment.isNotEmpty) {
      final overlay = OverlayBuilder(workspace, profile);
      try {
        final ov = await overlay.build(target.augment);
        _logger.info('Overlay: ${ov.prefix}');
      } on OverlayBuildException catch (e) {
        _logger.err(e.message);
        return ExitCode.software.code;
      } finally {
        overlay.close();
      }
    }

    if (args['build'] == true) {
      return _build(
        profile,
        target,
        workspace,
        inputPath,
        deb: args['deb'] == true,
        defaultName: manifest.id,
        selectedBackends: selectedBackends,
      );
    }
    return ExitCode.success.code;
  }

  /// Resolve the effective cross map. When the manifest defines
  /// `cross.targets`, merge the [targetName] entry over the shared fields
  /// (minus `targets`). Logs and returns null on a usage error.
  Map<dynamic, dynamic>? _selectCrossMap(
    Map<dynamic, dynamic> crossMap,
    String? targetName,
  ) {
    final targets = crossMap['targets'];
    final hasTargets = targets is Map && targets.isNotEmpty;

    if (!hasTargets) {
      if (targetName != null) {
        _logger.err('--target given but the manifest has no cross.targets.');
        return null;
      }
      return Map<dynamic, dynamic>.from(crossMap);
    }

    if (targetName == null) {
      _logger.err(
        'Manifest defines targets (${targets.keys.join(", ")}); '
        'pass --target <name>.',
      );
      return null;
    }
    final tdef = targets[targetName];
    if (tdef is! Map) {
      _logger.err(
        'Unknown target "$targetName". '
        'Available: ${targets.keys.join(", ")}',
      );
      return null;
    }
    // Shallow-merge shared fields (minus targets) then the target's overrides;
    // a top-level image_url override folds into the sysroot block.
    return {
      for (final e in crossMap.entries)
        if (e.key != 'targets') e.key: e.value,
      ...tdef,
    };
  }

  /// Configure + build the embedder under [profile], one build per
  /// `cross.backends` entry (or a single plain build when none are declared).
  /// The CMake/meson source is the package directory (the manifest file's
  /// parent for a file input).
  Future<int> _build(
    CrossProfile profile,
    CrossTarget target,
    Workspace workspace,
    String inputPath, {
    bool deb = false,
    String defaultName = 'app',
    List<String> selectedBackends = const [],
  }) async {
    final source =
        FileSystemEntity.typeSync(inputPath) == FileSystemEntityType.file
        ? File(inputPath).parent
        : Directory(inputPath);

    // A native `local` build: no sysroot, host toolchain, no augment staging.
    final native = profile.providerName == 'local';

    // --backend filters the matrix (validated in run()); merge shared
    // cross.defines into each backend (a backend define wins on a clash).
    final backends = {
      for (final e in target.backends.entries)
        if (selectedBackends.isEmpty || selectedBackends.contains(e.key))
          e.key: {...target.defines, ...e.value},
    };

    // Stage any augment libraries the sysroot doesn't already satisfy (e.g.
    // libdisplay-info >= 0.2.0) into the sysroot before configuring, so the
    // embedder's pkg-config probes resolve them. Native builds use the host's
    // system libraries instead (install via the manifest deps / emb deps).
    if (!native && target.augment.isNotEmpty) {
      final overlay = OverlayBuilder(workspace, profile);
      try {
        await overlay.build(
          target.augment,
          stageInto: Directory(profile.targetSysroot),
        );
      } on OverlayBuildException catch (e) {
        _logger.err('augment: ${e.message}');
        return ExitCode.software.code;
      } finally {
        overlay.close();
      }
    }

    final buildRoot = workspace.ensurePlatformDir(
      'cross-build-${profile.targetTriple}-${buildKey(target)}',
    );
    // Native keeps the host compiler env; cross neutralizes it.
    final builder = CrossBuilder(profile, neutralizeHostEnv: !native);

    final results = backends.isEmpty
        ? [
            await builder.build(
              sourceDir: source,
              buildDir: Directory('${buildRoot.path}/build'),
              generator: target.generator,
              defines: target.defines,
              cmakeArgs: target.cmakeArgs,
            ),
          ]
        : await builder.buildBackends(
            sourceDir: source,
            buildRoot: buildRoot,
            generator: target.generator,
            backends: backends,
            cmakeArgs: target.cmakeArgs,
          );

    for (final r in results) {
      final tag = r.backend != null ? '${r.backend}: ' : '';
      if (r.success) {
        _logger.info('  ${tag}built → ${r.buildDir}');
      } else {
        _logger.err('  $tag${r.message ?? "build failed"}');
      }
    }
    if (!results.every((r) => r.success)) return ExitCode.software.code;

    if (deb) {
      return _packageDebs(
        profile,
        target,
        buildRoot,
        results.where((r) => r.success).toList(),
        defaultName,
      );
    }
    return ExitCode.success.code;
  }

  /// Remove the selected target's cross working dirs and report freed space.
  /// `--clean` keeps the expensive toolchain + sysroot (the keyed
  /// `cross-<triple>-<key>` dir); `--clean-all` ([all]) removes those plus the
  /// shared overlay sources too.
  Future<int> _clean(
    CrossProvider provider,
    CrossTarget target,
    Workspace workspace, {
    required bool all,
  }) async {
    final triple = provider.triple;
    final sk = sysrootKey(target);
    final dirs = <Directory>[
      workspace.platformDir('cross-build-$triple-${buildKey(target)}'),
      workspace.platformDir('overlay-$triple'),
      if (all) ...[
        workspace.platformDir('cross-$triple-$sk'),
        workspace.platformDir('overlay-src'),
        if (provider.name == 'yocto-sdk')
          workspace.platformDir('yocto-sdk-$sk'),
      ],
    ];

    var freed = 0;
    var removed = 0;
    for (final dir in dirs) {
      if (!dir.existsSync()) continue;
      final bytes = _dirSize(dir);
      dir.deleteSync(recursive: true);
      freed += bytes;
      removed++;
      _logger.info('  removed ${dir.path} (${_human(bytes)})');
    }
    if (removed == 0) {
      _logger.info('Nothing to clean for $triple.');
    } else {
      _logger.info('Freed ${_human(freed)}.');
      if (!all) {
        _logger.detail(
          'Kept the toolchain + sysroot; use --clean-all to remove those.',
        );
      }
    }
    return ExitCode.success.code;
  }

  /// Total size of [dir] in bytes, not following symlinks.
  int _dirSize(Directory dir) {
    var total = 0;
    for (final e in dir.listSync(recursive: true, followLinks: false)) {
      if (e is File) {
        try {
          total += e.lengthSync();
        } on FileSystemException {
          // Dangling entry mid-delete; ignore.
        }
      }
    }
    return total;
  }

  String _human(int bytes) {
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    var n = bytes.toDouble();
    var i = 0;
    while (n >= 1024 && i < units.length - 1) {
      n /= 1024;
      i++;
    }
    return '${n.toStringAsFixed(i == 0 || n >= 100 ? 0 : 1)}${units[i]}';
  }

  /// Package each successfully-built backend binary into a `.deb` under
  /// `<buildRoot>/dist`. Multiple backends get a `-<backend>` name suffix.
  Future<int> _packageDebs(
    CrossProfile profile,
    CrossTarget target,
    Directory buildRoot,
    List<CrossBuildResult> built,
    String defaultName,
  ) async {
    final spec = target.package ?? const PackageSpec();
    final arch = debianArch(profile.targetTriple);
    final baseName = spec.name ?? defaultName;
    final outDir = Directory(p.join(buildRoot.path, 'dist'));
    // The resolver's downloaded `.deb`s sit beside the sysroot, in `debs/`.
    final debDirs = [
      Directory(p.join(p.dirname(profile.targetSysroot), 'debs')),
    ];
    final packager = DebPackager(readelf: _readelfFor(profile));

    for (final r in built) {
      final binary = _artifactFor(r.buildDir, spec.bin);
      if (binary == null) {
        _logger.err(
          '  ${r.backend ?? ""}: no binary to package in ${r.buildDir} '
          '(set cross.package.bin)',
        );
        return ExitCode.software.code;
      }
      final multi = built.length > 1 && r.backend != null;
      final name = multi ? '$baseName-${r.backend}' : baseName;
      final meta = DebMetadata(
        name: name,
        version: spec.version,
        architecture: arch,
        maintainer: spec.maintainer,
        description: spec.description ?? '$name (cross-built by emb for $arch)',
        section: spec.section,
        priority: spec.priority,
        dependsExtra: spec.depends,
        autoDepends: spec.autoDepends,
      );
      try {
        final out = await packager.build(
          binary: binary,
          installPath: p.join(spec.installDir, p.basename(binary.path)),
          meta: meta,
          outDir: outDir,
          sysroot: Directory(profile.targetSysroot),
          debDirs: debDirs,
        );
        _logger.info('  ${r.backend ?? ""}: packaged → ${out.path}');
      } on DebPackageException catch (e) {
        _logger.err('  ${r.backend ?? ""}: ${e.message}');
        return ExitCode.software.code;
      }
    }
    return ExitCode.success.code;
  }

  /// The binary to package: [bin] resolved under [buildDir], else the first ELF
  /// executable found there.
  File? _artifactFor(String buildDir, String? bin) {
    if (bin != null) {
      final f = File(p.join(buildDir, bin));
      return f.existsSync() ? f : null;
    }
    for (final e in Directory(buildDir).listSync(recursive: true)) {
      if (e is! File) continue;
      final stat = e.statSync();
      // Executable bit + ELF magic.
      if (stat.mode & 0x49 == 0) continue;
      final head = e.openSync()..setPositionSync(0);
      final magic = head.readSync(4);
      head.closeSync();
      if (magic.length == 4 &&
          magic[0] == 0x7f &&
          magic[1] == 0x45 &&
          magic[2] == 0x4c &&
          magic[3] == 0x46) {
        return e;
      }
    }
    return null;
  }

  /// Derive the cross `readelf` path from the profile's `gcc`.
  String _readelfFor(CrossProfile profile) =>
      profile.cc.replaceFirst(RegExp(r'gcc$'), 'readelf');

  void _report(CrossProfile p) {
    _logger
      ..info(styleBold.wrap('Cross profile (${p.providerName})'))
      ..info('  triple        : ${p.targetTriple}')
      ..info('  cc            : ${p.cc}')
      ..info('  target sysroot: ${p.targetSysroot}')
      ..info('  native sysroot: ${p.nativeSysroot ?? "-"}')
      ..info('  cmake tc file : ${p.cmakeToolchainFile ?? "(emit)"}')
      ..info('  meson cross   : ${p.mesonCrossFile ?? "(emit/none)"}')
      ..info('  cpu flags     : ${p.cFlags.join(" ")}');
  }

  /// Report the resolution plan with no download / mount / ssh side effects.
  Future<void> _plan(
    CrossProvider provider,
    CrossTarget target,
    HostInfo host,
  ) async {
    final missing = await _missingTools(provider.preflightTools);
    _logger
      ..info(styleBold.wrap('Cross plan (${provider.name})'))
      ..info('  triple        : ${target.triple ?? "(provider default)"}')
      ..info('  cpu flags     : ${target.cpuFlags.join(" ")}')
      ..info('  host          : ${host.os.name}/${host.machineArch}')
      ..info(
        '  preflight     : '
        '${missing.isEmpty ? "ok" : "MISSING ${missing.join(", ")}"}',
      );
    switch (target.provider) {
      case CrossProviderKind.armGnu:
        final tc = target.versionPolicy == ToolchainVersionPolicy.pinned
            ? (target.toolchainVersion ?? '(unset!)')
            : 'derive from sysroot codename';
        final s = target.sysroot;
        final sysroot = switch (s?.source) {
          SysrootProvenance.image => 'image  ${s?.imageUrl}',
          SysrootProvenance.device =>
            'device ${s?.deviceHost} (ssh:${s?.sshPort})',
          null => '(none configured)',
        };
        _logger
          ..info('  toolchain     : $tc')
          ..info('  sysroot       : $sysroot');
        if (host.os != HostOs.linux) {
          _logger.info('  note          : resolve needs a Linux host + root');
        }
      case CrossProviderKind.yoctoRecipe:
        final build = target.yoctoBuild;
        final present = build != null && Directory(build).existsSync();
        _logger
          ..info(
            '  recipe        : ${target.recipe} @ ${build ?? "(unset!)"} '
            '${present ? "[present]" : "[absent]"}',
          )
          ..info('  machine tuple : ${target.machineTuple ?? "(unset!)"}');
      case CrossProviderKind.yoctoSdk:
        final loc = target.sdkEnvSetup ?? target.sdkPath ?? target.sdkUrl;
        final isUrl =
            target.sdkUrl != null &&
            target.sdkPath == null &&
            target.sdkEnvSetup == null;
        final present = target.sdkEnvSetup != null
            ? File(target.sdkEnvSetup!).existsSync()
            : target.sdkPath != null && Directory(target.sdkPath!).existsSync();
        final state = isUrl
            ? '[download]'
            : (present ? '[present]' : '[absent]');
        _logger.info('  sdk           : ${loc ?? "(none!)"} $state');
    }
    if (target.augment.isNotEmpty) {
      _logger.info(
        '  augment       : ${target.augment.map((a) => a.pkg).join(", ")}',
      );
    }
    if (target.backends.isNotEmpty) {
      _logger.info(
        '  backends      : ${target.backends.keys.join(", ")} '
        '(${target.generator.name})',
      );
    }
  }

  Future<List<String>> _missingTools(List<String> tools) async {
    final missing = <String>[];
    for (final t in tools) {
      final r = await Process.run('which', [t]);
      if (r.exitCode != 0) missing.add(t);
    }
    return missing;
  }
}
