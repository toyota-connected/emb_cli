import 'dart:io';

import 'package:emb_cli/src/cross/boards_dir.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

/// A configured board-library source. Boards from each source land in their
/// own subdirectory of the data dir, so names never collide across sources.
sealed class BoardSource {
  const BoardSource({required this.name});

  /// Unique name used in `extends: <name>/<target>` and on disk.
  final String name;

  Map<String, dynamic> toMap();

  static BoardSource fromMap(Map<String, dynamic> map) {
    final name = map['name'] as String? ?? '';
    return switch (map['type']) {
      'github' => GithubBoardSource(
        name: name,
        repo: map['repo'] as String? ?? '',
        path: map['path'] as String? ?? 'boards',
        ref: map['ref'] as String? ?? 'auto',
        tokenEnv: map['token_env'] as String?,
        transport: map['transport'] as String? ?? 'https',
      ),
      'local' => LocalBoardSource(
        name: name,
        path: map['path'] as String? ?? '',
      ),
      final t => throw ArgumentError('unknown board source type: $t'),
    };
  }
}

/// A GitHub repository containing board manifests.
class GithubBoardSource extends BoardSource {
  const GithubBoardSource({
    required super.name,
    required this.repo,
    this.path = 'boards',
    this.ref = 'auto',
    this.tokenEnv,
    this.transport = 'https',
  });

  final String repo;
  final String path;
  final String ref;
  final String? tokenEnv;
  final String transport;

  bool get useSsh => transport == 'ssh';

  @override
  Map<String, dynamic> toMap() => {
    'name': name,
    'type': 'github',
    'repo': repo,
    'path': path,
    'ref': ref,
    if (tokenEnv != null) 'token_env': tokenEnv,
    if (transport != 'https') 'transport': transport,
  };
}

/// A local directory of board manifests — no sync needed.
class LocalBoardSource extends BoardSource {
  const LocalBoardSource({required super.name, required this.path});

  final String path;

  @override
  Map<String, dynamic> toMap() => {
    'name': name,
    'type': 'local',
    'path': path,
  };
}

/// The default source — matches the pre-multi-source behavior.
const defaultSource = GithubBoardSource(
  name: 'emb-public',
  repo: 'toyota-connected/emb_cli',
);

/// Loaded board-sources config. Reads `boards.yaml` from the emb config dir.
class BoardSourceConfig {
  BoardSourceConfig(this.sources);

  /// Load from [file], falling back to the single default source.
  factory BoardSourceConfig.load(File file) {
    if (!file.existsSync()) return BoardSourceConfig([defaultSource]);
    try {
      final yaml = loadYaml(file.readAsStringSync());
      if (yaml is! Map) return BoardSourceConfig([defaultSource]);
      final list = yaml['sources'];
      if (list is! List || list.isEmpty) {
        return BoardSourceConfig([defaultSource]);
      }
      return BoardSourceConfig([
        for (final e in list)
          if (e is Map) BoardSource.fromMap(Map<String, dynamic>.from(e)),
      ]);
    } on Object {
      return BoardSourceConfig([defaultSource]);
    }
  }

  final List<BoardSource> sources;

  /// Write the config to [file] as YAML.
  void save(File file) {
    file.parent.createSync(recursive: true);
    final buf = StringBuffer()..writeln('sources:');
    for (final s in sources) {
      final map = s.toMap();
      var first = true;
      for (final e in map.entries) {
        final prefix = first ? '  - ' : '    ';
        first = false;
        buf.writeln('$prefix${e.key}: ${_scalar(e.value.toString())}');
      }
    }
    file.writeAsStringSync(buf.toString());
  }

  /// Find a source by name, or null.
  BoardSource? operator [](String name) {
    for (final s in sources) {
      if (s.name == name) return s;
    }
    return null;
  }

  /// Whether a source with [name] exists.
  bool contains(String name) => this[name] != null;

  static String _scalar(String v) => "'${v.replaceAll("'", "''")}'";
}

/// Resolve the board-sources config file path.
File resolveBoardSourcesFile({Map<String, String>? environment}) {
  final env = environment ?? Platform.environment;
  return File(
    p.join(resolveConfigDir(environment: env).path, 'emb', 'boards.yaml'),
  );
}

/// XDG config home (or platform equivalent). Parallels [dataHomeDir].
Directory resolveConfigDir({
  Map<String, String>? environment,
  String? operatingSystem,
}) {
  final env = environment ?? Platform.environment;
  final os = operatingSystem ?? Platform.operatingSystem;

  if (os == 'windows') {
    final local = env['LOCALAPPDATA'];
    if (local != null && local.isNotEmpty) return Directory(local);
    final profile = env['USERPROFILE'];
    if (profile != null && profile.isNotEmpty) {
      return Directory(p.join(profile, 'AppData', 'Local'));
    }
    return Directory(Directory.systemTemp.path);
  }

  final home = env['HOME'] ?? env['USERPROFILE'] ?? Directory.systemTemp.path;

  if (os == 'macos') {
    return Directory(p.join(home, 'Library', 'Application Support'));
  }

  final xdg = env['XDG_CONFIG_HOME'];
  if (xdg != null && xdg.isNotEmpty) return Directory(xdg);
  return Directory(p.join(home, '.config'));
}
