import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:emb_cli/src/cross/cross_project.dart';
import 'package:emb_cli/src/cross/cross_target.dart';
import 'package:emb_cli/src/cross/flatpak_packager.dart';
import 'package:emb_cli/src/init/flatpak_repo_template.dart';
import 'package:emb_cli/src/version.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

/// Runs a host tool (`git`, `flatpak`) for [InitFlatpakCommand]; injectable so
/// tests need neither the network nor flatpak.
///
/// Throws [TimeoutException] when [timeout] passes with the tool still
/// running.
typedef InitProcessRunner =
    Future<ProcessResult> Function(
      String executable,
      List<String> args, {
      Map<String, String>? environment,
      Duration? timeout,
    });

/// The real [InitProcessRunner]. `Process.run` cannot be bounded: a timeout on
/// its future leaves the child running and its pipes open, so the tool is
/// started, and killed when [timeout] passes.
@visibleForTesting
Future<ProcessResult> runInitTool(
  String executable,
  List<String> args, {
  Map<String, String>? environment,
  Duration? timeout,
}) async {
  final process = await Process.start(
    executable,
    args,
    environment: environment,
  );
  // Nothing here answers a question; a tool that reads stdin gets EOF.
  unawaited(process.stdin.close().catchError((Object _) {}));
  final out = process.stdout.transform(systemEncoding.decoder).join();
  final err = process.stderr.transform(systemEncoding.decoder).join();
  final code = timeout == null
      ? await process.exitCode
      : await process.exitCode.timeout(
          timeout,
          onTimeout: () {
            process.kill(ProcessSignal.sigkill);
            // The pipes may outlive the kill (a transport helper holds them),
            // so the output is abandoned, not awaited.
            unawaited(out.catchError((Object _) => ''));
            unawaited(err.catchError((Object _) => ''));
            throw TimeoutException('$executable did not answer', timeout);
          },
        );
  return ProcessResult(process.pid, code, await out, await err);
}

/// Git environment that cannot stop for input, the rule `emb boards sync`
/// follows: a credential prompt in the middle of a run is a hang.
/// `GIT_SSH_COMMAND` is extended, not replaced, so a key or wrapper the user
/// set survives.
@visibleForTesting
Map<String, String> gitNoPromptEnvironment(Map<String, String> environment) {
  final ssh = environment['GIT_SSH_COMMAND']?.trim();
  return {
    'GIT_TERMINAL_PROMPT': '0',
    'GIT_SSH_COMMAND': [
      if (ssh == null || ssh.isEmpty) 'ssh' else ssh,
      '-o',
      'BatchMode=yes',
    ].join(' '),
  };
}

/// One round trip each; bounded because the failure is a stall, not an error.
const _gitTimeout = Duration(minutes: 1);
const _flatpakTimeout = Duration(seconds: 30);

/// Why [uri] is not handed to git, or null when it is one emb will pass on.
///
/// The value becomes a git argument now and `cross.source.uri` in the
/// manifest, which a later build clones. A leading `-` would be read as an
/// option (`--upload-pack=<command>` runs the command), and a transport such
/// as `ext::` runs one by design.
String? _uriProblem(String uri) {
  if (uri.startsWith('-')) return 'it starts with "-"';
  if (RegExp(r'[\s\x00-\x1f\x7f]').hasMatch(uri)) {
    return 'it contains whitespace';
  }
  final scheme = RegExp(
    '^([A-Za-z][A-Za-z0-9+.-]*)://',
  ).firstMatch(uri)?.group(1);
  if (scheme != null) {
    return const {
          'https',
          'http',
          'ssh',
          'git',
          'file',
        }.contains(scheme.toLowerCase())
        ? null
        : 'the "$scheme" transport is not one of https, http, ssh, git, file';
  }
  if (RegExp(r'^[\w.-]+@[\w.-]+:\S').hasMatch(uri)) return null;
  return 'expected https://..., ssh://... or git@host:path';
}

final _revPattern = RegExp(r'^[A-Za-z0-9][\w./-]*$');
final _commitPattern = RegExp(r'^[0-9a-fA-F]+$');
final _runtimePattern = RegExp(r'^\d\d\.\d\d$');
final _flutterVersionPattern = RegExp(r'^[A-Za-z0-9][\w.+-]*$');
final _binPattern = RegExp(r'^[\w.+-]+(/[\w.+-]+)*$');
final _targetPattern = RegExp(r'^[A-Za-z0-9][\w.-]*$');
final _pubNamePattern = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$');
final _pubVersionPattern = RegExp(r'^[0-9A-Za-z][0-9A-Za-z.+-]*$');

/// {@template init_command}
/// `emb init <format>` — generate a packaging repo for one format.
///
/// A dispatcher from the start, with `flatpak` the only format, so a second
/// one is a subcommand and not a restructuring.
/// {@endtemplate}
class InitCommand extends Command<int> {
  /// {@macro init_command}
  InitCommand({
    required Logger logger,
    InitProcessRunner? processRunner,
    CrossProjectResolver? resolver,
    DateTime Function()? now,
  }) {
    addSubcommand(
      InitFlatpakCommand(
        logger: logger,
        processRunner: processRunner,
        resolver: resolver,
        now: now,
      ),
    );
  }

  @override
  String get description => 'Generate a packaging repo (flatpak).';

  @override
  String get name => 'init';
}

/// {@template init_flatpak_command}
/// `emb init flatpak <dir> --app-id <id>` — write a self-contained flatpak
/// packaging repo: a cross manifest naming its own embedder, app, Flutter SDK
/// and runtime, plus the README, `.gitignore`, AppStream metadata and CI
/// around it. Non-interactive; everything comes from flags or is inferred.
/// {@endtemplate}
class InitFlatpakCommand extends Command<int> {
  /// {@macro init_flatpak_command}
  InitFlatpakCommand({
    required Logger logger,
    InitProcessRunner? processRunner,
    CrossProjectResolver? resolver,
    DateTime Function()? now,
  }) : _logger = logger,
       _run = processRunner ?? runInitTool,
       _resolver = resolver ?? CrossProjectResolver(),
       _now = now ?? DateTime.now {
    argParser
      ..addOption(
        'app-id',
        help: 'Reverse-DNS flatpak app id, e.g. com.example.MyApp.',
        mandatory: true,
      )
      ..addOption(
        'app',
        help:
            'The Flutter app. A git URI is written into the manifest as '
            'cross.app; a local directory only supplies the name, version '
            'and description from its pubspec.yaml.',
      )
      ..addOption(
        'app-rev',
        help: 'Commit of --app <uri> to pin (default: its HEAD, resolved now).',
      )
      ..addOption(
        'embedder',
        help: 'Git URI of the embedder, written as cross.source.',
        defaultsTo: defaultEmbedderUri,
      )
      ..addOption(
        'embedder-rev',
        help: 'Embedder commit to pin (default: its HEAD, resolved now).',
      )
      ..addOption(
        'embedder-bin',
        help:
            'The embedder binary, relative to its build directory '
            '(default for ivi-homescreen: $defaultEmbedderBin).',
      )
      ..addOption(
        'provider',
        help: 'Cross provider the manifest declares.',
        allowed: [for (final k in CrossProviderKind.values) k.token],
        defaultsTo: CrossProviderKind.armGnu.token,
      )
      ..addMultiOption(
        'target',
        help:
            'A board target to add, by the name the embedder gives it in '
            "its .emb/ (extends: 'source#<name>'). Repeatable. Not checked "
            'until the first build clones the embedder.',
      )
      ..addMultiOption(
        'sdk',
        help:
            'An architecture to build against the flatpak SDK rather than '
            'this machine, as target sdk-<arch>. Repeatable. With x86_64, '
            'the CI workflow builds that target.',
        allowed: const ['x86_64', 'aarch64'],
      )
      ..addOption(
        'backend',
        help:
            'The embedder backend a --target build is for (default for '
            'ivi-homescreen: $defaultEmbedderBackend).',
      )
      ..addOption(
        'runtime-version',
        help:
            'freedesktop runtime branch (default: the newest flathub offers, '
            'else $defaultFlatpakRuntimeVersion).',
      )
      ..addOption(
        'flutter-version',
        help: 'Flutter SDK branch or tag the manifest pins.',
        defaultsTo: 'stable',
      )
      ..addOption(
        'ci',
        help: 'CI workflow to generate. Needs --app <uri>.',
        allowed: const ['none', 'github'],
        defaultsTo: 'github',
      )
      ..addFlag(
        'force',
        help:
            'Write into a non-empty directory. Only files emb generated are '
            'replaced; any other file is left as it is.',
        negatable: false,
      );
  }

  final Logger _logger;
  final InitProcessRunner _run;
  final CrossProjectResolver _resolver;

  /// The clock the release date in `metainfo.xml` is read from.
  final DateTime Function() _now;

  /// [when] as AppStream wants a release date: `YYYY-MM-DD`, in UTC so the
  /// same instant gives the same file on every machine.
  static String _isoDate(DateTime when) {
    final utc = when.toUtc();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${utc.year.toString().padLeft(4, '0')}-${two(utc.month)}-'
        '${two(utc.day)}';
  }

  @override
  String get description =>
      'Generate a self-contained flatpak packaging repo in <dir>.';

  @override
  String get name => 'flatpak';

  @override
  String get invocation => 'emb init flatpak <dir> --app-id <id> [options]';

  @override
  Future<int> run() async {
    final args = argResults!;
    if (args.rest.length != 1) {
      throw UsageException(
        args.rest.isEmpty
            ? 'init flatpak: missing the directory to generate into.'
            : 'init flatpak: unexpected argument "${args.rest[1]}".',
        usage,
      );
    }
    final dir = Directory(args.rest.single);
    final force = args['force'] as bool;

    // Reading an unset mandatory option throws ArgumentError, which would
    // reach the user as a crash and not as usage.
    if (!args.wasParsed('app-id')) {
      throw UsageException('init flatpak: --app-id is required.', usage);
    }
    final appId = args['app-id'] as String;
    if (!looksLikeFlatpakAppId(appId)) {
      _logger.err(
        'Invalid flatpak app id "$appId": expected reverse-DNS with at '
        'least three segments, e.g. com.example.MyApp.',
      );
      return ExitCode.usage.code;
    }

    // Refuse before any network work: a directory that cannot be written is
    // known now, and resolving two remotes first only delays saying so.
    final dirType = FileSystemEntity.typeSync(dir.path);
    if (dirType != FileSystemEntityType.notFound &&
        dirType != FileSystemEntityType.directory) {
      _logger.err('${dir.path} exists and is not a directory.');
      return ExitCode.cantCreate.code;
    }
    // `git init` first is the natural order, so `.git` alone is still empty.
    if (!force &&
        dir.existsSync() &&
        dir.listSync().any((e) => p.basename(e.path) != '.git')) {
      _logger.err(
        '${dir.path} is not empty. Pass --force to write into it; files emb '
        'did not generate are left alone.',
      );
      return ExitCode.cantCreate.code;
    }

    // Every value below is written into a file someone will build from, and
    // some into a shell line. Each is held to the shape it has to have, here,
    // before the network is asked anything.
    final runtimeArg = args['runtime-version'] as String?;
    if (runtimeArg != null && !_runtimePattern.hasMatch(runtimeArg)) {
      return _usage(
        '--runtime-version "$runtimeArg": expected a freedesktop runtime '
        'branch such as $defaultFlatpakRuntimeVersion.',
      );
    }
    final flutterVersion = args['flutter-version'] as String;
    if (!_flutterVersionPattern.hasMatch(flutterVersion)) {
      return _usage(
        '--flutter-version "$flutterVersion": expected a branch or a tag.',
      );
    }
    final binArg = args['embedder-bin'] as String?;
    if (binArg != null &&
        (!_binPattern.hasMatch(binArg) ||
            binArg.startsWith('-') ||
            p.posix.split(binArg).any((s) => s == '..' || s == '.'))) {
      return _usage(
        '--embedder-bin "$binArg": expected a path relative to the '
        "embedder's build directory, e.g. $defaultEmbedderBin.",
      );
    }
    // A target is named after the embedder's own, which is not there to look
    // at until a build clones it. Only the shape can be held here.
    final targets = args['target'] as List<String>;
    for (final target in targets) {
      if (!_targetPattern.hasMatch(target)) {
        return _usage(
          '--target "$target": expected the name of a target the embedder '
          'defines, e.g. rpi5-trixie.',
        );
      }
      if (target == 'local' || target == 'host') {
        return _usage(
          '--target $target: "$target" is the built-in native build, which '
          'every generated repo already has. Name a board target.',
        );
      }
    }
    if (targets.toSet().length != targets.length) {
      return _usage('--target: a name is given more than once.');
    }
    final sdkArches = args['sdk'] as List<String>;
    if (sdkArches.toSet().length != sdkArches.length) {
      return _usage('--sdk: an architecture is given more than once.');
    }
    for (final a in sdkArches) {
      final name = FlatpakRepoSpec.sdkTargetName(a);
      if (targets.contains(name)) {
        return _usage(
          '--target $name: the name --sdk $a gives its own target.',
        );
      }
    }
    final backendArg = args['backend'] as String?;
    if (backendArg != null && !_targetPattern.hasMatch(backendArg)) {
      return _usage(
        '--backend "$backendArg": expected a backend name, e.g. '
        '$defaultEmbedderBackend.',
      );
    }
    if (backendArg != null && targets.isEmpty) {
      return _usage(
        '--backend needs --target: the native build is not given one.',
      );
    }
    final embedderUri = args['embedder'] as String;
    final embedderProblem = _uriProblem(embedderUri);
    if (embedderProblem != null) {
      return _usage(
        '--embedder "$embedderUri" is not a git URI: $embedderProblem.',
      );
    }
    for (final flag in const ['embedder-rev', 'app-rev']) {
      final rev = args[flag] as String?;
      if (rev == null) continue;
      if (!_revPattern.hasMatch(rev)) {
        return _usage('--$flag "$rev": expected a commit.');
      }
      if (!_commitPattern.hasMatch(rev)) {
        _logger.warn(
          '--$flag $rev is not a commit id. A branch or a tag can move, and '
          'the build will follow it.',
        );
      }
    }

    // --app: a URI goes into the manifest, a directory only describes the app.
    final appArg = args['app'] as String?;
    final appIsUri = appArg != null && _isGitUri(appArg);
    if (appIsUri) {
      final problem = _uriProblem(appArg);
      if (problem != null) {
        return _usage('--app "$appArg" is not a git URI: $problem.');
      }
    }
    _Pubspec? pubspec;
    if (appArg != null && !appIsUri) {
      final read = _readPubspec(Directory(appArg));
      if (read.problem != null) {
        return _usage('--app $appArg: ${read.problem}');
      }
      pubspec = read.pubspec;
    }
    if (args['app-rev'] != null && !appIsUri) {
      _logger.err('--app-rev needs --app <uri>.');
      return ExitCode.usage.code;
    }

    final embedder = await _pin(
      'embedder',
      embedderUri,
      args['embedder-rev'] as String?,
      flag: '--embedder-rev',
    );
    if (embedder == null) return ExitCode.unavailable.code;
    PinnedRepo? app;
    if (appIsUri) {
      app = await _pin(
        'app',
        appArg,
        args['app-rev'] as String?,
        flag: '--app-rev',
      );
      if (app == null) return ExitCode.unavailable.code;
    }

    final wantsCi = args['ci'] == 'github';
    // Only ivi-homescreen's layout is known: where its binary is, which
    // backend runs under a compositor, and what its board layer expects that
    // a generated repo does not have.
    final knownEmbedder = embedder.uri == defaultEmbedderUri;
    final spec = FlatpakRepoSpec(
      appId: appId,
      id: pubspec == null ? idFromAppId(appId) : kebabCase(pubspec.name),
      name: pubspec?.name ?? appId.split('.').last,
      version: pubspec?.version ?? '0.1.0',
      summary: pubspec?.description,
      embedder: embedder,
      // For any other embedder the manifest says the binary should be
      // named, and why.
      embedderBin: binArg ?? (knownEmbedder ? defaultEmbedderBin : null),
      targets: targets,
      sdkArches: sdkArches,
      backend: targets.isEmpty
          ? null
          : backendArg ?? (knownEmbedder ? defaultEmbedderBackend : null),
      targetDefines: knownEmbedder && targets.isNotEmpty
          ? defaultEmbedderTargetDefines
          : const {},
      targetDefinesWhy: knownEmbedder && targets.isNotEmpty
          ? defaultEmbedderTargetDefinesWhy
          : const [],
      app: app,
      provider: args['provider'] as String,
      runtimeVersion: runtimeArg ?? await _newestRuntime(),
      flutterVersion: flutterVersion,
      githubCi: wantsCi,
      embVersion: packageVersion,
      releaseDate: _isoDate(_now()),
    );
    if (spec.id.isEmpty) {
      _logger.err('Could not derive a package name from "$appId".');
      return ExitCode.usage.code;
    }

    final files = renderFlatpakRepo(spec);
    final problem = _verify(files, spec);
    if (problem != null) {
      // Every value was checked above, so a manifest that does not load is a
      // defect in the template.
      _logger.err(problem);
      return ExitCode.software.code;
    }

    final binaries = renderFlatpakRepoBinaries(spec);
    final contents = <String, List<int>>{
      for (final e in files.entries) e.key: utf8.encode(e.value),
      ...binaries,
    };
    // Decide everything, then write: a file that cannot be read or a path
    // that cannot be created is found before the first byte goes out, so a
    // failure does not leave half a repo.
    final _Plan plan;
    try {
      plan = _plan(dir, contents, binaries.keys.toSet());
    } on _PlanProblem catch (e) {
      _logger.err('${e.message} Nothing was written.');
      return ExitCode.cantCreate.code;
    } on FileSystemException catch (e) {
      _logger.err(
        'Could not read ${e.path ?? dir.path}: ${e.message}. '
        'Nothing was written.',
      );
      return ExitCode.cantCreate.code;
    }
    try {
      for (final entry in contents.entries) {
        if (plan.kept.contains(entry.key)) continue;
        File(p.join(dir.path, entry.key))
          ..createSync(recursive: true)
          ..writeAsBytesSync(entry.value);
      }
      for (final rel in plan.stale) {
        File(p.join(dir.path, rel)).deleteSync();
      }
    } on FileSystemException catch (e) {
      _logger.err('Could not write ${e.path ?? dir.path}: ${e.message}.');
      return ExitCode.ioError.code;
    }
    for (final rel in contents.keys) {
      _logger.info(
        plan.kept.contains(rel)
            ? '  kept     $rel (not generated by emb)'
            : '  wrote    $rel',
      );
    }
    for (final rel in plan.stale) {
      _logger.info('  removed  $rel (generated by an earlier run)');
    }
    if (wantsCi && !spec.emitsWorkflow) {
      _logger.info(
        '  no CI workflow: the app is not named in the manifest, so a runner '
        'would have nothing to build. Pass --app <uri> to get one.',
      );
    }
    _logger
      ..info('')
      ..info('Next, in ${dir.path}:')
      ..info('  ${spec.buildCommand}');
    for (final target in spec.allTargets) {
      _logger.info('  ${spec.buildCommandFor(target)}');
    }
    if (spec.targets.isNotEmpty) {
      _logger.info(
        '\n${spec.targets.join(', ')}: not checked against the embedder, '
        'which is cloned by the first build. See README.md for the runtime '
        'a board build needs.',
      );
    }
    return ExitCode.success.code;
  }

  int _usage(String message) {
    _logger.err(message);
    return ExitCode.usage.code;
  }

  bool _isGitUri(String value) =>
      value.contains('://') || RegExp(r'^[\w.-]+@[\w.-]+:').hasMatch(value);

  /// [uri] pinned to [rev], or to its HEAD when [rev] is null. Null (after
  /// reporting) when HEAD cannot be resolved.
  ///
  /// A commit, not a branch: a branch floats and the build breaks at a
  /// distance. The branch is kept beside it as the thing to edit.
  Future<PinnedRepo?> _pin(
    String what,
    String uri,
    String? rev, {
    required String flag,
  }) async {
    if (rev != null) return PinnedRepo(uri: uri, rev: rev);
    _logger.info('Resolving HEAD of $uri');
    final ProcessResult r;
    try {
      r = await _run(
        'git',
        ['ls-remote', '--symref', '--', uri, 'HEAD'],
        environment: gitNoPromptEnvironment(Platform.environment),
        timeout: _gitTimeout,
      );
    } on ProcessException catch (e) {
      _logger.err('Could not run git to resolve the $what: ${e.message}');
      return null;
    } on TimeoutException {
      _logger.err(
        'No answer from $uri after ${_gitTimeout.inSeconds}s. '
        'Pass $flag <commit> to pin the $what without the network.',
      );
      return null;
    }
    String? sha;
    String? branch;
    for (final line in (r.stdout as String).split('\n')) {
      final fields = line.trim().split(RegExp(r'\s+'));
      if (fields.length == 3 && fields[0] == 'ref:' && fields[2] == 'HEAD') {
        branch = fields[1].replaceFirst('refs/heads/', '');
      } else if (fields.length == 2 && fields[1] == 'HEAD') {
        sha = fields[0];
      }
    }
    // A commit id is all that is taken from the remote, and only as one.
    if (r.exitCode != 0 || sha == null || !_commitPattern.hasMatch(sha)) {
      final said = (r.stderr as String).trim().split('\n').first;
      final why = said.isEmpty
          ? 'the remote has no HEAD; an empty repository?'
          : said;
      _logger.err(
        'Could not resolve HEAD of $uri ($why). '
        'Pass $flag <commit> to pin the $what without the network.',
      );
      return null;
    }
    return PinnedRepo(
      uri: uri,
      rev: sha,
      // Written into a comment; anything that is not a ref name is dropped.
      branch: branch != null && _revPattern.hasMatch(branch) ? branch : null,
    );
  }

  /// The newest `org.freedesktop.Platform` branch flathub offers, as seen by
  /// the user or the system installation; the fallback when flatpak is not
  /// installed or has no flathub remote.
  Future<String> _newestRuntime() async {
    final branches = <String>{};
    for (final scope in const ['--user', '--system']) {
      try {
        final r = await _run('flatpak', [
          'remote-ls',
          scope,
          '--runtime',
          '--columns=application,branch',
          'flathub',
        ], timeout: _flatpakTimeout);
        if (r.exitCode != 0) continue;
        for (final line in (r.stdout as String).split('\n')) {
          final fields = line.trim().split(RegExp(r'\s+'));
          if (fields.length == 2 &&
              fields[0] == 'org.freedesktop.Platform' &&
              _runtimePattern.hasMatch(fields[1])) {
            branches.add(fields[1]);
          }
        }
      } on ProcessException {
        continue;
      } on TimeoutException {
        continue;
      }
      if (branches.isNotEmpty) break;
    }
    if (branches.isEmpty) return defaultFlatpakRuntimeVersion;
    // `YY.MM`, zero-padded, so string order is version order.
    return (branches.toList()..sort()).last;
  }

  /// Resolves the rendered manifest the way `emb cross` would, from a scratch
  /// copy, so nothing is written into the user's directory unless what is
  /// written will load. Returns the problem, or null.
  String? _verify(Map<String, String> files, FlatpakRepoSpec spec) {
    final scratch = Directory.systemTemp.createTempSync('emb-init-');
    try {
      final manifest = File(p.join(scratch.path, spec.manifestName))
        ..writeAsStringSync(files[spec.manifestName]!);
      // A board target extends into the embedder, which is not cloned here,
      // so it cannot resolve yet. It is set aside, and held to having been
      // written as what it was meant to be.
      final project = _resolver.resolve(manifest.path, deferExtends: true);
      if (project == null) return 'no manifest was produced';
      final selection = project.selectTarget('local');
      if (selection == null) return 'target "local" is missing';
      final target = CrossTarget.fromMap(selection.cross);
      if (target.package?.flatpak?.appId != spec.appId) {
        return 'package.flatpak.app_id did not survive';
      }
      for (final name in spec.targets) {
        final pending = project.unresolved[name];
        if (pending == null) return 'target "$name" is missing';
        if (pending.block['extends'] != 'source#$name') {
          return 'target "$name" does not extend source#$name';
        }
        if (CrossTarget.repoFrom(pending.block['source']) == null) {
          return 'target "$name" has no cross.source to extend into';
        }
      }
      for (final arch in spec.sdkArches) {
        final name = FlatpakRepoSpec.sdkTargetName(arch);
        final sdk = project.selectTarget(name);
        if (sdk == null) return 'target "$name" is missing';
        final t = CrossTarget.fromMap(sdk.cross);
        if (t.provider != CrossProviderKind.flatpakSdk) {
          return 'target "$name" is not a flatpak-sdk target';
        }
        if (t.targetTriple != '$arch-flatpak-linux-gnu') {
          return 'target "$name" is not for $arch';
        }
        // A target's package: would replace the shared one wholesale.
        if (t.package?.flatpak?.appId != spec.appId) {
          return 'target "$name" lost package.flatpak';
        }
      }
      // With no targets a flat manifest is one implicit target of its own.
      if (spec.allTargets.isNotEmpty &&
          (project.targets.length != spec.sdkArches.length ||
              project.unresolved.length != spec.targets.length)) {
        return 'the manifest has targets that were not asked for';
      }
      return null;
    } on CrossProjectException catch (e) {
      // Name the file the user will have, not the scratch copy.
      return e.message.replaceAll('${scratch.path}${p.separator}', '');
      // The manifest parser reports a bad value by throwing ArgumentError.
      // ignore: avoid_catching_errors
    } on ArgumentError catch (e) {
      return '${e.message}';
    } on FormatException catch (e) {
      return e.message;
      // A scalar the template left unquoted and YAML read as a number or a
      // bool. A defect in the template, reported instead of thrown.
      // ignore: avoid_catching_errors
    } on TypeError catch (e) {
      return 'the rendered manifest does not load: $e';
    } finally {
      scratch.deleteSync(recursive: true);
    }
  }

  /// What writing [contents] under [dir] will do, with nothing written yet.
  ///
  /// A file already there is replaced only when it is emb's: a text file
  /// that still opens with [flatpakInitMarker], or one of [binaries] that is
  /// still byte for byte what emb writes. A generated manifest or workflow
  /// from an earlier run that this run does not write is stale: it would go
  /// on building what the earlier flags said.
  ///
  /// Nothing is written through a symbolic link. A linked file is the user's
  /// and is kept; a linked directory on the way to a file is refused, since
  /// the file would land outside [dir].
  _Plan _plan(
    Directory dir,
    Map<String, List<int>> contents,
    Set<String> binaries,
  ) {
    FileSystemEntityType typeOf(String rel) =>
        FileSystemEntity.typeSync(p.join(dir.path, rel), followLinks: false);

    /// The first thing on the way to [rel] that is not a real directory,
    /// with its type; null when every parent that exists is one.
    (String, FileSystemEntityType)? blockedParent(String rel) {
      final parts = p.split(rel);
      for (var i = 1; i < parts.length; i++) {
        final parent = p.joinAll(parts.take(i));
        final type = typeOf(parent);
        if (type == FileSystemEntityType.notFound) return null;
        if (type != FileSystemEntityType.directory) return (parent, type);
      }
      return null;
    }

    bool isOurs(String rel) {
      final bytes = File(p.join(dir.path, rel)).readAsBytesSync();
      final expected = contents[rel];
      if (binaries.contains(rel)) {
        return expected != null &&
            bytes.length == expected.length &&
            Iterable<int>.generate(
              bytes.length,
            ).every((i) => bytes[i] == expected[i]);
      }
      // The marker is the first line of a generated file, or the second
      // below an XML declaration. Anywhere else it is prose quoting it.
      final head = utf8
          .decode(bytes.take(1024).toList(), allowMalformed: true)
          .split('\n')
          .take(2);
      return head.any((line) => line.contains(flatpakInitMarker));
    }

    final kept = <String>{};
    for (final rel in contents.keys) {
      final blocked = blockedParent(rel);
      if (blocked != null) {
        final what = blocked.$2 == FileSystemEntityType.link
            ? 'a symbolic link'
            : 'not a directory';
        throw _PlanProblem(
          '${blocked.$1} is $what, so $rel cannot be written under it.',
        );
      }
      final type = typeOf(rel);
      if (type == FileSystemEntityType.notFound) continue;
      if (type == FileSystemEntityType.directory) {
        throw _PlanProblem('$rel is a directory.');
      }
      if (type == FileSystemEntityType.link || !isOurs(rel)) kept.add(rel);
    }

    final stale = <String>[];
    if (dir.existsSync()) {
      const workflow = '.github/workflows/flatpak.yml';
      final candidates = [
        for (final e in dir.listSync(followLinks: false))
          if (e is File && e.path.endsWith('.emb.yaml')) p.basename(e.path),
        workflow,
      ];
      for (final rel in candidates) {
        if (contents.containsKey(rel)) continue;
        if (typeOf(rel) != FileSystemEntityType.file) continue;
        if (blockedParent(rel) != null) continue;
        if (isOurs(rel)) stale.add(rel);
      }
    }
    return _Plan(kept: kept, stale: stale);
  }

  /// The app's pubspec, or why it cannot be used. Its values go into the
  /// README and the AppStream metadata, and the app may be someone else's, so
  /// each is held to what pub itself allows.
  ({_Pubspec? pubspec, String? problem}) _readPubspec(Directory app) {
    const unreadable =
        'no readable pubspec.yaml there. Give a Flutter app directory, or a '
        'git URI.';
    final file = File(p.join(app.path, 'pubspec.yaml'));
    if (!file.existsSync()) return (pubspec: null, problem: unreadable);
    final Object? doc;
    try {
      doc = loadYaml(file.readAsStringSync());
    } on YamlException {
      return (pubspec: null, problem: unreadable);
    } on FileSystemException {
      // Not UTF-8, or not readable.
      return (pubspec: null, problem: unreadable);
    }
    if (doc is! YamlMap) return (pubspec: null, problem: unreadable);
    final name = doc['name']?.toString();
    if (name == null || name.isEmpty) {
      return (pubspec: null, problem: unreadable);
    }
    if (!_pubNamePattern.hasMatch(name)) {
      return (
        pubspec: null,
        problem: 'its pubspec.yaml has a name that is not a package name.',
      );
    }
    // `1.2.3+4`: the build number means nothing to a package version.
    final version = doc['version']?.toString().split('+').first;
    if (version != null && !_pubVersionPattern.hasMatch(version)) {
      return (
        pubspec: null,
        problem: 'its pubspec.yaml has a version that is not a version.',
      );
    }
    final description = doc['description']
        ?.toString()
        .trim()
        .split('\n')
        .first
        .replaceAll(RegExp(r'[\x00-\x1f\x7f]'), ' ')
        .trim();
    return (
      pubspec: _Pubspec(
        name: name,
        version: version,
        description: description == null || description.isEmpty
            ? null
            : description,
      ),
      problem: null,
    );
  }
}

class _Plan {
  const _Plan({required this.kept, required this.stale});

  /// Generated paths left as they are: not emb's to replace.
  final Set<String> kept;

  /// Paths an earlier run generated and this one does not: removed.
  final List<String> stale;
}

class _PlanProblem implements Exception {
  const _PlanProblem(this.message);

  final String message;
}

class _Pubspec {
  const _Pubspec({required this.name, this.version, this.description});

  final String name;
  final String? version;
  final String? description;
}
