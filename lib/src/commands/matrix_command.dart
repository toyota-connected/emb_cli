import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:emb_cli/src/cross/cross_keys.dart';
import 'package:emb_cli/src/cross/cross_provider.dart';
import 'package:emb_cli/src/cross/cross_target.dart';
import 'package:emb_cli/src/host/host_info.dart';
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
  }) : _logger = logger,
       _host = host,
       _loader = loader {
    argParser
      ..addMultiOption(
        'host',
        help:
            'Restrict to these host types (intersected with each '
            "manifest's supported_host_types). Default: every supported host.",
      )
      ..addOption('target', help: 'Only emit the cells for this target name.')
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
    final workspace = Workspace.resolve();

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

      for (final entry in _targets(crossMap)) {
        if (targetFilter != null && entry.name != targetFilter) continue;
        final CrossTarget target;
        try {
          target = CrossTarget.fromMap(entry.merged);
          // fromMap throws ArgumentError on an unknown/missing provider token.
          // ignore: avoid_catching_errors
        } on ArgumentError catch (e) {
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
            'sysroot_key': sysrootKey(target),
            'build_key': buildKey(target),
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
