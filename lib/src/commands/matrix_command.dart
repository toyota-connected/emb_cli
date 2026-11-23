import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:emb_cli/src/cross/cross_keys.dart';
import 'package:emb_cli/src/cross/cross_project.dart';
import 'package:emb_cli/src/cross/cross_provider.dart';
import 'package:emb_cli/src/cross/cross_target.dart';
import 'package:emb_cli/src/cross/source_checkout.dart';
import 'package:emb_cli/src/host/host_info.dart';
import 'package:emb_cli/src/manifest/build_config.dart';
import 'package:emb_cli/src/manifest/emb_manifest.dart';
import 'package:emb_cli/src/manifest/manifest_loader.dart';
import 'package:emb_cli/src/workspace/workspace.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:path/path.dart' as p;

/// {@template matrix_command}
/// `emb matrix <manifest|dir>...` — render a CI build matrix from the `cross:`
/// blocks of one or more manifests.
///
/// Emits GitHub Actions `{"include":[...]}` JSON: one cell per
/// (manifest × target × supported host). Each cell carries the `emb cross`
/// args to run, the provider/triple, the host runner (`runs_on`,
/// optionally `container`), the provider's preflight tools, and the
/// content-addressed `sysroot_key`/`build_key` for `actions/cache`.
///
/// Side-effect free — it only parses manifests (no download/mount/ssh), so it
/// runs on any host. Pair each cell with `emb cross <args> --dry-run` as a
/// per-cell PR gate, and (opt-in) `emb cross <args> --build` for the real
/// cross build keyed on the cache keys.
/// {@endtemplate}
class MatrixCommand extends Command<int> {
  /// {@macro matrix_command}
  MatrixCommand({
    required Logger logger,
    HostInfo? host,
    ManifestLoader loader = const ManifestLoader(),
    CrossProjectResolver? resolver,
  }) : _logger = logger,
       _host = host,
       _loader = loader,
       _resolver = resolver ?? CrossProjectResolver(loader) {
    argParser
      ..addMultiOption(
        'host',
        help:
            'Restrict to these host types (intersected with each '
            "manifest's supported_host_types). Default: every supported host.",
      )
      ..addOption('target', help: 'Only emit the cells for this target name.')
      ..addOption(
        'workspace',
        abbr: 'w',
        help:
            "Workspace root (defaults to each manifest's workspace:, then "
            r'$FLUTTER_WORKSPACE, then cwd). Where the checkout of a '
            'cross.source is looked for.',
      )
      ..addFlag(
        'fetch',
        help:
            "Clone a cross.source that an extends: 'source#<target>' target "
            'needs and the workspace does not have. Off by default: without '
            'it nothing is downloaded, and such a target is skipped.',
        negatable: false,
      )
      ..addOption(
        'output',
        abbr: 'o',
        help:
            'Write the JSON to this file instead of stdout (robust against '
            'banners polluting a captured stdout).',
      )
      ..addFlag(
        'pretty',
        help: 'Indent the JSON (stdout only).',
        negatable: false,
      );
  }

  final Logger _logger;
  final HostInfo? _host;
  final ManifestLoader _loader;
  final CrossProjectResolver _resolver;

  @override
  String get name => 'matrix';

  @override
  String get description =>
      'Render a CI build matrix from manifest cross: blocks.';

  @override
  Future<int> run() async {
    final args = argResults!;
    if (args.rest.isEmpty) {
      _logger.err(
        'Usage: emb matrix <manifest|dir>... [--host h] [--target t] [-o file]',
      );
      return ExitCode.usage.code;
    }

    final hostFilter = args['host'] as List<String>;
    final targetFilter = args['target'] as String?;
    final host = _host ?? HostInfo.detect();
    final workspaceArg = args['workspace'] as String?;
    final fetch = args['fetch'] == true;

    final include = <Map<String, dynamic>>[];
    for (final input in _collect(args.rest)) {
      // Resolved as `emb cross` resolves it, so the cells are the targets
      // `emb cross <input> --list-targets` shows: a `.emb/` project's base
      // merged under each board file, `extends:` followed.
      var project = _resolve(input);
      if (project == null) continue;
      final workspace = resolveBuildWorkspace(project, override: workspaceArg);

      // `extends: 'source#<target>'` names a target inside the embedder's
      // repo, so it resolves only once that repo is on disk.
      final reasons = <String, String>{};
      final sourceDirs = <String, String>{};
      for (final pending in project.unresolved.values) {
        if (targetFilter != null && pending.name != targetFilter) continue;
        if (!_extendsSource(pending.block)) continue;
        final found = await _sourceCheckout(
          pending.block,
          workspace,
          pending.sourcePath,
          fetch: fetch,
        );
        if (found.dir == null) {
          reasons[pending.name] = found.why;
        } else {
          sourceDirs[pending.name] = found.dir!;
        }
      }
      if (sourceDirs.isNotEmpty) {
        project = _resolve(input, sourceDirs: sourceDirs) ?? project;
      }
      for (final pending in project.unresolved.values) {
        if (targetFilter != null && pending.name != targetFilter) continue;
        _logger.warn(
          'skip $input#${pending.name}: '
          '${reasons[pending.name] ?? pending.message}',
        );
      }

      final root = _projectRoot(input);
      for (final ref in project.targets.values) {
        // A flat manifest's one target is the one `emb cross <manifest>`
        // builds with no --target: its cell is `default`, as it always was.
        final flat = project.defaultTarget == ref.name;
        final name = flat ? 'default' : ref.name;
        if (targetFilter != null && name != targetFilter) continue;

        final declaring = _manifestOf(ref.sourcePath, project);
        final hosts = _hosts(declaring, hostFilter);
        if (hosts.isEmpty) continue;
        // On stderr, as `emb cross` prints it, so -o output stays clean (#370).
        for (final w in ref.warnings) {
          _logger.warn('$input#$name: $w');
        }
        if (declaresAppPath(declaring?.raw['build'])) {
          _logger.warn(
            '${ref.sourcePath ?? input}: build.app_path is deprecated and has '
            'no effect; pass --app <path> on the command line instead.',
          );
        }

        final CrossTarget target;
        try {
          target = CrossTarget.fromMap(
            ref.cross,
          ).withResolvedPaths(ref.sourcePath, vars: {'embedder_root': root});
          // fromMap throws ArgumentError on an unknown/missing provider token.
          // ignore: avoid_catching_errors
        } on ArgumentError catch (e) {
          _logger.warn('skip $input#$name: ${e.message}');
          continue;
        }
        final provider = CrossProvider.forTarget(
          target,
          workspace: workspace,
          host: host,
        );
        final crossArgs = flat ? input : '$input --target $name';

        if (target.hasUnresolvedKeyPaths) {
          _logger.warn(
            '$input#$name: augment/module paths contain '
            r'unbound ${app_root} — sysroot_key/build_key omitted '
            '(they require --app to resolve)',
          );
        }

        for (final h in hosts) {
          final runner = _runner(h);
          include.add({
            'id': project.id,
            'manifest': ref.sourcePath ?? input,
            'target': name,
            'host': h,
            'runs_on': runner.runsOn,
            if (runner.container != null) 'container': runner.container,
            'provider': target.provider.token,
            'triple': target.triple ?? '',
            'preflight': provider.preflightTools.join(' '),
            if (!target.hasUnresolvedKeyPaths) ...{
              'sysroot_key': sysrootKey(target),
              'build_key': buildKey(target),
            },
            'args': crossArgs,
          });
        }
      }
    }

    final payload = {'include': include};
    final outPath = args['output'] as String?;
    if (outPath != null) {
      File(outPath).writeAsStringSync(jsonEncode(payload));
      final n = include.length;
      _logger.info('Wrote $outPath ($n cell${n == 1 ? "" : "s"}).');
    } else {
      _logger.info(
        (args['pretty'] as bool)
            ? const JsonEncoder.withIndent('  ').convert(payload)
            : jsonEncode(payload),
      );
    }
    return ExitCode.success.code;
  }

  /// [input] as a project, with targets that do not resolve set aside, or
  /// null after saying why there is none. A manifest with no `cross:` block
  /// is not a cross project and is passed over quietly.
  CrossProject? _resolve(
    String input, {
    Map<String, String> sourceDirs = const {},
  }) {
    if (FileSystemEntity.isFileSync(input)) {
      final manifest = _loader.loadManifestFile(File(input));
      if (manifest == null) {
        _logger.warn('skip $input: not a manifest');
        return null;
      }
      if (manifest.raw['cross'] is! Map) return null;
    }
    try {
      final project = _resolver.resolve(
        input,
        deferExtends: true,
        sourceDirs: sourceDirs,
      );
      if (project == null) _logger.warn('skip $input: no emb project');
      return project;
    } on CrossProjectException catch (e) {
      _logger.warn('skip $input: ${e.message}');
      return null;
    }
  }

  /// The manifest whose `supported_host_types` and `build:` apply to a
  /// target: the file that declared it, unless that names no hosts and the
  /// project has a base manifest that does (a `.emb/` board file and its
  /// `base.emb.yaml`).
  EmbManifest? _manifestOf(String? sourcePath, CrossProject project) {
    EmbManifest? load(String? path) =>
        path == null ? null : _loader.loadManifestFile(File(path));
    final own = load(sourcePath);
    if (own != null && own.supportedHostTypes.isNotEmpty) return own;
    final base = project.nativeSourcePath == sourcePath
        ? null
        : load(project.nativeSourcePath);
    if (base != null && base.supportedHostTypes.isNotEmpty) return base;
    return own ?? base;
  }

  /// [manifest]'s `supported_host_types`, `ubuntu` when it names none,
  /// narrowed by `--host`.
  static List<String> _hosts(EmbManifest? manifest, List<String> filter) {
    final declared = manifest?.supportedHostTypes ?? const <String>[];
    final supported = declared.isEmpty ? const ['ubuntu'] : declared;
    return filter.isEmpty
        ? supported
        : filter.where(supported.contains).toList();
  }

  /// The directory `${embedder_root}` names for [input]: the project
  /// directory, or the directory of a manifest given as a file.
  static String _projectRoot(String input) {
    final abs = p.normalize(p.absolute(input));
    return FileSystemEntity.isDirectorySync(abs) ? abs : p.dirname(abs);
  }

  static bool _extendsSource(Map<dynamic, dynamic> block) {
    final ref = block['extends'];
    return ref is String &&
        ref.startsWith('${CrossProjectResolver.sourceRef}#');
  }

  /// The checkout of [block]'s `cross.source` in [workspace], cloned first
  /// when [fetch] asks, or why there is none.
  Future<({String? dir, String why})> _sourceCheckout(
    Map<dynamic, dynamic> block,
    Workspace workspace,
    String? sourcePath, {
    required bool fetch,
  }) async {
    final repo = CrossTarget.repoFrom(block['source']);
    if (repo == null) {
      return (
        dir: null,
        why:
            'extends: "${block['extends']}" needs a cross.source, and the '
            'manifest declares none',
      );
    }
    final dest = sourceCheckoutDir(repo, workspace);
    if (!fetch) {
      if (dest.existsSync()) return (dir: dest.path, why: '');
      return (
        dir: null,
        why:
            'extends: "${block['extends']}" needs the checkout of '
            'cross.source (${repo.uri}), which is not in ${dest.path}. Pass '
            '--fetch to clone it, or run `emb fetch` first.',
      );
    }
    final cloned = await cloneSourceRepo(
      repo,
      workspace,
      sourcePath: sourcePath,
    );
    return cloned.dir == null
        ? (
            dir: null,
            why:
                'cross.source (${repo.uri}) could not be fetched: '
                '${cloned.message}',
          )
        : (dir: cloned.dir!.path, why: '');
  }

  /// What to render, from the given paths:
  ///
  /// - a file is one manifest;
  /// - a directory holding a `.emb/` is one project, as `emb cross` reads it;
  /// - a `.emb/` directory itself is the project that holds it;
  /// - any other directory contributes its `emb.yaml` and every `*.emb.yaml`
  ///   directly inside it, sorted, each read as a manifest.
  ///
  /// Deduplicated by absolute path.
  List<String> _collect(List<String> paths) {
    final seen = <String>{};
    final inputs = <String>[];
    void add(String path) {
      if (seen.add(p.normalize(p.absolute(path)))) inputs.add(path);
    }

    for (final path in paths) {
      final type = FileSystemEntity.typeSync(path);
      if (type == FileSystemEntityType.file) {
        add(path);
      } else if (type == FileSystemEntityType.directory) {
        if (p.basename(p.normalize(p.absolute(path))) == '.emb') {
          add(p.dirname(p.normalize(p.absolute(path))));
        } else if (Directory(p.join(path, '.emb')).existsSync()) {
          add(path);
        } else {
          final embYaml = File(p.join(path, 'emb.yaml'));
          if (embYaml.existsSync()) add(embYaml.path);
          (Directory(path)
                  .listSync()
                  .whereType<File>()
                  .where((f) => f.path.endsWith('.emb.yaml'))
                  .map((f) => f.path)
                  .toList()
                ..sort())
              .forEach(add);
        }
      } else {
        _logger.warn('skip: no such path $path');
      }
    }
    return inputs;
  }

  /// Map a host type to a GitHub Actions runner. Distros without a hosted
  /// runner ride an `ubuntu-latest` host inside a container image.
  ({String runsOn, String? container}) _runner(String hostType) {
    if (hostType == 'fedora') {
      return (runsOn: 'ubuntu-latest', container: 'fedora:41');
    }
    if (hostType == 'darwin' || hostType == 'macos') {
      return (runsOn: 'macos-latest', container: null);
    }
    if (hostType == 'windows') {
      return (runsOn: 'windows-latest', container: null);
    }
    return (runsOn: 'ubuntu-latest', container: null); // ubuntu/debian/default
  }
}
