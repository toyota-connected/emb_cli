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
    for (final file in _collect(args.rest)) {
      final manifest = _loader.loadManifestFile(file);
      if (manifest == null) {
        _logger.warn('skip ${file.path}: not a manifest');
        continue;
      }
      final crossMap = manifest.raw['cross'];
      if (crossMap is! Map) continue; // not a cross manifest — silently skip

      // Hosts: the manifest's declared support, narrowed by --host. Empty
      // supported_host_types falls back to ubuntu so a terse manifest emits.
      final supported = manifest.supportedHostTypes.isEmpty
          ? const ['ubuntu']
          : manifest.supportedHostTypes;
      final hosts = hostFilter.isEmpty
          ? supported
          : hostFilter.where(supported.contains).toList();
      if (hosts.isEmpty) continue;

      if (declaresAppPath(manifest.raw['build'])) {
        _logger.warn(
          '${file.path}: build.app_path is deprecated and has no effect; '
          'pass --app <path> on the command line instead.',
        );
      }

      final workspace = _workspaceFor(file, workspaceArg);

      for (final entry in _targets(crossMap)) {
        if (targetFilter != null && entry.name != targetFilter) continue;
        // `extends: 'source#<target>'` names a target inside the embedder's
        // repo, so the cell exists only once that repo is on disk.
        String? sourceDir;
        if (_extendsSource(entry.merged)) {
          final found = await _sourceCheckout(
            entry.merged,
            workspace,
            file,
            fetch: fetch,
          );
          if (found.dir == null) {
            _logger.warn('skip ${file.path}#${entry.name}: ${found.why}');
            continue;
          }
          sourceDir = found.dir;
        }
        final CrossTarget target;
        try {
          // Resolve the target's `extends` chain (board library / cross-project)
          // first, so a target whose provider comes from a board — like the
          // rpi family — yields a real cell instead of being skipped.
          final resolved = _resolver.resolveExtends(
            Map<String, dynamic>.from(entry.merged),
            file.path,
            sourceDir: sourceDir,
          );
          target = CrossTarget.fromMap(resolved).withResolvedPaths(
            file.path,
            vars: {
              'embedder_root': p.normalize(p.dirname(p.absolute(file.path))),
            },
          );
          // fromMap throws ArgumentError on an unknown/missing provider token;
          // extends resolution throws CrossProjectException (bad board/ref).
          // ignore: avoid_catching_errors
        } on ArgumentError catch (e) {
          _logger.warn('skip ${file.path}#${entry.name}: ${e.message}');
          continue;
        } on CrossProjectException catch (e) {
          _logger.warn('skip ${file.path}#${entry.name}: ${e.message}');
          continue;
        }
        final provider = CrossProvider.forTarget(
          target,
          workspace: workspace,
          host: host,
        );
        // `default` is the single-target shape (no cross.targets); it needs no
        // --target. A named target does.
        final crossArgs = entry.name == 'default'
            ? file.path
            : '${file.path} --target ${entry.name}';

        if (target.hasUnresolvedKeyPaths) {
          _logger.warn(
            '${file.path}#${entry.name}: augment/module paths contain '
            r'unbound ${app_root} — sysroot_key/build_key omitted '
            '(they require --app to resolve)',
          );
        }

        for (final h in hosts) {
          final runner = _runner(h);
          include.add({
            'id': manifest.id,
            'manifest': file.path,
            'target': entry.name,
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

  /// The workspace [file] builds in, by the rule `emb cross` uses: `-w`, the
  /// manifest's `workspace:`, `$FLUTTER_WORKSPACE`, cwd. A manifest that does
  /// not resolve as a project still has the last three.
  Workspace _workspaceFor(File file, String? override) {
    try {
      final project = _resolver.resolve(file.path, deferExtends: true);
      if (project != null) {
        return resolveBuildWorkspace(project, override: override);
      }
    } on CrossProjectException {
      // Reported per target below, where it can name the target.
    }
    return Workspace.resolve(override: override);
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
    File file, {
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
      sourcePath: file.path,
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

  /// Expand a `cross:` map into its targets. A `cross.targets` map yields one
  /// entry per named target (shared fields merged under each override); a flat
  /// `cross:` yields a single synthetic `default` target.
  List<({String name, Map<dynamic, dynamic> merged})> _targets(
    Map<dynamic, dynamic> crossMap,
  ) {
    final targets = crossMap['targets'];
    if (targets is Map && targets.isNotEmpty) {
      return [
        for (final e in targets.entries)
          if (e.value is Map)
            (
              name: e.key.toString(),
              merged: <dynamic, dynamic>{
                for (final s in crossMap.entries)
                  if (s.key != 'targets') s.key: s.value,
                ...e.value as Map,
              },
            ),
      ];
    }
    return [(name: 'default', merged: Map<dynamic, dynamic>.from(crossMap))];
  }

  /// Gather manifest files from the given paths: a file is taken as-is; a
  /// directory contributes its `emb.yaml` (if any) plus every `*.emb.yaml`
  /// (sorted). Deduplicated by absolute path.
  List<File> _collect(List<String> paths) {
    final seen = <String>{};
    final files = <File>[];
    void add(File f) {
      if (seen.add(p.absolute(f.path))) files.add(f);
    }

    for (final path in paths) {
      final type = FileSystemEntity.typeSync(path);
      if (type == FileSystemEntityType.file) {
        add(File(path));
      } else if (type == FileSystemEntityType.directory) {
        final embYaml = File(p.join(path, 'emb.yaml'));
        if (embYaml.existsSync()) add(embYaml);
        Directory(path)
            .listSync()
            .whereType<File>()
            .where((f) => f.path.endsWith('.emb.yaml'))
            .toList()
          ..sort((a, b) => a.path.compareTo(b.path))
          ..forEach(add);
      } else {
        _logger.warn('skip: no such path $path');
      }
    }
    return files;
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
