import 'dart:io';

import 'package:emb_cli/src/cross/process_runner.dart';
import 'package:emb_cli/src/cross/run_command.dart';
import 'package:path/path.dart' as p;

/// Manifest metadata for a generated `.flatpak` bundle.
///
/// A flatpak wraps the whole runnable bundle (embedder + `data/` + `lib/`) in a
/// sandboxed app under a reverse-DNS [appId], built against a freedesktop (or
/// custom) runtime. Defaults target a Wayland Flutter shell.
class FlatpakMetadata {
  const FlatpakMetadata({
    required this.appId,
    required this.command,
    this.branch = 'stable',
    this.runtime = 'org.freedesktop.Platform',
    this.runtimeVersion = '23.08',
    this.sdk = 'org.freedesktop.Sdk',
    this.arch,
    this.finishArgs = defaultFinishArgs,
    this.appName,
    this.icon,
    this.categories = const ['Utility'],
    this.env = const {},
    this.args = const [],
    this.libDirOnPath = false,
    this.runCommand,
  });

  /// A reasonable sandbox for a Wayland Flutter shell: Wayland socket, GPU,
  /// audio, and shared IPC. Override via `cross.package.flatpak.finish_args`.
  static const List<String> defaultFinishArgs = [
    '--share=ipc',
    '--socket=wayland',
    '--socket=fallback-x11',
    '--device=dri',
    '--socket=pulseaudio',
  ];

  /// Reverse-DNS application id, e.g. `com.toyota.ivi.Homescreen`. Doubles as
  /// the install prefix (`/app/<appId>`), `.desktop` basename, and icon name.
  final String appId;

  /// The embedder binary (basename) the launcher wrapper execs.
  final String command;

  /// `cross.run.command` — how this embedder is told where its bundle is, as
  /// `--run` spells it. The launcher takes its bundle flag from here, so a
  /// manifest declares that once rather than once for `--run` and again as a
  /// `flatpak.args` entry carrying `{bundle}`.
  ///
  /// Null falls back to [defaultRunTemplate], which is `-b`. Ignored when
  /// `flatpak.args` places `{bundle}` itself — an explicit arg list is the more
  /// specific statement of the two.
  final List<String>? runCommand;

  final String branch;
  final String runtime;
  final String runtimeVersion;
  final String sdk;

  /// flatpak arch (`aarch64`, `x86_64`, `arm`); null builds for the host arch.
  final String? arch;

  /// Sandbox permissions (`finish-args`).
  final List<String> finishArgs;

  /// `.desktop` display name; defaults to the appId's last segment.
  final String? appName;

  /// Host path to a PNG/SVG icon installed into the hicolor theme. Optional.
  final File? icon;

  /// `.desktop` `Categories`.
  final List<String> categories;

  /// Environment the launcher exports before exec'ing the embedder. Plain
  /// assignments, except `*PATH`/`*DIRS` names, which prepend.
  final Map<String, String> env;

  /// Extra arguments the launcher passes to the embedder.
  final List<String> args;

  /// Put the bundle's `lib/` on `LD_LIBRARY_PATH` in the launcher. Vendored
  /// libraries carry no RUNPATH, so their own dependencies are found only this
  /// way.
  final bool libDirOnPath;
}

/// Thrown when packaging a `.flatpak` fails.
class FlatpakPackageException implements Exception {
  FlatpakPackageException(this.message);
  final String message;
  @override
  String toString() => 'FlatpakPackageException: $message';
}

/// Builds a single-file `.flatpak` from a runnable bundle via
/// `flatpak-builder`.
///
/// Mirrors `DebPackager` in shape — stage, emit metadata, invoke the system
/// packaging tool — but a flatpak wraps the *whole* app: the bundle tree is
/// copied to `/app/<appId>`, a launcher wrapper (`exec <embedder> -b <prefix>`,
/// or whatever [FlatpakMetadata.args] spells with `{bundle}`)
/// is installed on `PATH`, and a `.desktop` (+ optional icon) make it a
/// first-class sandboxed app. Extra files map host paths into the `/app`
/// prefix.
///
/// Needs `flatpak-builder` plus the target runtime/SDK installed on the build
/// host (`flatpak install org.freedesktop.Platform//<ver>` etc.); a missing
/// `flatpak-builder` is reported up front.
class FlatpakPackager {
  FlatpakPackager({ProcessRunner runProcess = defaultProcessRunner})
    : _run = runProcess;

  final ProcessRunner _run;

  /// Package [bundleDir] (embedder + `data/` + `lib/`) into
  /// `<outDir>/<appId>_<branch>_<arch>.flatpak`. [extraFiles] maps host source
  /// paths to destinations under the `/app` prefix (a leading `/` is treated as
  /// relative to `/app`).
  Future<File> build({
    required Directory bundleDir,
    required FlatpakMetadata meta,
    required Directory outDir,
    Map<String, String> extraFiles = const {},
    Map<String, String> fileModes = const {},
    Future<void> Function(Directory stagedBundle)? onStaged,
  }) async {
    if (!bundleDir.existsSync()) {
      throw FlatpakPackageException('bundle not found: ${bundleDir.path}');
    }
    if (!File(p.join(bundleDir.path, meta.command)).existsSync()) {
      throw FlatpakPackageException(
        'embedder "${meta.command}" not found in ${bundleDir.path}',
      );
    }
    if (!_looksLikeAppId(meta.appId)) {
      throw FlatpakPackageException(
        'invalid flatpak app id "${meta.appId}" '
        '(need reverse-DNS, e.g. com.example.App)',
      );
    }
    if (await _which('flatpak-builder') == null) {
      final ver = meta.runtimeVersion;
      throw FlatpakPackageException(
        'flatpak-builder not found on PATH — install it plus the runtime, '
        'e.g.\n'
        '    flatpak install flathub '
        'org.freedesktop.Platform//$ver org.freedesktop.Sdk//$ver',
      );
    }

    outDir.createSync(recursive: true);
    final ctx = Directory(p.join(outDir.path, '${meta.appId}.flatpak-ctx'));
    if (ctx.existsSync()) ctx.deleteSync(recursive: true);
    ctx.createSync(recursive: true);

    // Stage the bundle tree the manifest's `dir` source copies from.
    final staged = Directory(p.join(ctx.path, 'bundle'));
    await _copyTree(bundleDir, staged);
    if (onStaged != null) await onStaged(staged);

    // Launcher wrapper: run the embedder against its in-prefix bundle dir.
    final prefix = '/app/${meta.appId}';
    File(
      p.join(ctx.path, 'launcher.sh'),
    ).writeAsStringSync(_launcher(meta, prefix));

    final desktopName = meta.appName ?? meta.appId.split('.').last;
    File(
      p.join(ctx.path, '${meta.appId}.desktop'),
    ).writeAsStringSync(_desktop(meta, desktopName));
    if (meta.icon != null) {
      if (!meta.icon!.existsSync()) {
        throw FlatpakPackageException('icon not found: ${meta.icon!.path}');
      }
      final ext = p.extension(meta.icon!.path);
      meta.icon!.copySync(p.join(ctx.path, 'icon$ext'));
    }

    // Stage extra files under extra/<n>, recording their /app destinations.
    final extras = <_Extra>[];
    if (extraFiles.isNotEmpty) {
      Directory(p.join(ctx.path, 'extra')).createSync();
    }
    var i = 0;
    for (final entry in extraFiles.entries) {
      final src = File(entry.key);
      if (!src.existsSync()) {
        throw FlatpakPackageException('extra file not found: ${entry.key}');
      }
      final rel = 'extra/$i';
      src.copySync(p.join(ctx.path, rel));
      extras.add(_Extra(rel, _appDest(entry.value), fileModes[entry.key]));
      i++;
    }

    final manifest = File(p.join(ctx.path, '${meta.appId}.yml'))
      ..writeAsStringSync(_manifest(meta, prefix, desktopName, extras));

    final repo = Directory(p.join(ctx.path, 'repo'));
    final builderArgs = [
      '--force-clean',
      '--disable-rofiles-fuse',
      '--repo=${repo.path}',
      if (meta.arch != null) '--arch=${meta.arch}',
      p.join(ctx.path, 'builddir'),
      manifest.path,
    ];
    final br = await _run(
      'flatpak-builder',
      builderArgs,
      workingDirectory: ctx.path,
      output: ProcessOutputMode.stream,
    );
    if (br.exitCode != 0) {
      throw FlatpakPackageException('flatpak-builder failed: ${br.stderr}');
    }

    final out = File(
      p.join(
        outDir.path,
        '${meta.appId}_${meta.branch}_${meta.arch ?? "host"}.flatpak',
      ),
    );
    final bundleRes = await _run('flatpak', [
      'build-bundle',
      if (meta.arch != null) '--arch=${meta.arch}',
      repo.path,
      out.path,
      meta.appId,
      meta.branch,
    ], output: ProcessOutputMode.stream);
    if (bundleRes.exitCode != 0) {
      throw FlatpakPackageException(
        'flatpak build-bundle failed: ${bundleRes.stderr}',
      );
    }
    ctx.deleteSync(recursive: true);
    return out;
  }

  /// The `/app/bin/<command>` launcher wrapper: the embedder exec'd against its
  /// bundle, carrying [FlatpakMetadata.env] and [FlatpakMetadata.args]. The
  /// caller's `"$@"` stays last, so `flatpak run <app> --flag` still reaches
  /// the embedder.
  String _launcher(FlatpakMetadata m, String prefix) {
    _validate(m);
    final b = StringBuffer('#!/bin/sh\n');
    if (m.libDirOnPath) _emitEnv(b, 'LD_LIBRARY_PATH', '$prefix/lib');
    for (final e in m.env.entries) {
      if (m.libDirOnPath &&
          e.key == 'LD_LIBRARY_PATH' &&
          e.value == '$prefix/lib') {
        continue;
      }
      _emitEnv(b, e.key, e.value);
    }
    final placed = m.args.any((a) => a.contains(_bundleToken));
    final words = [
      if (!placed) ..._bundleArgs(m, prefix),
      ...m.args.map((a) => _shellWord(a.replaceAll(_bundleToken, prefix))),
    ];
    // Joined with the exec line rather than interpolated as one string: a
    // `run.command` naming no bundle flag leaves this empty, and an empty
    // interpolation put a double space in the generated script.
    b.writeln(['exec $prefix/${m.command}', ...words, r'"$@"'].join(' '));
    return b.toString();
  }

  /// How to tell the embedder where its bundle is, taken from
  /// `cross.run.command` so one declaration covers `--run` and this launcher.
  ///
  /// `-b` used to be written here as a literal, which meant an embedder
  /// spelling it differently worked under `--run` (once `run.command` existed)
  /// and was still handed `-b` inside the sandbox. The default template is
  /// `-b`, so a manifest that says nothing is unaffected.
  ///
  /// The template describes a whole command line, of which this needs only the
  /// part after the executable — the launcher execs `$prefix/<command>` itself.
  /// Dropping the first token is only right when that token *is* the embedder,
  /// so a template starting with anything else (a wrapper like `sh -c …`) is
  /// refused rather than silently mangled: `flatpak.args` with `{bundle}` is
  /// the way to express that, and it takes precedence anyway.
  ///
  /// The bundle path becomes absolute. Every other consumer of this template
  /// runs *inside* the bundle — `--run` and the deploy transports all cd there
  /// first — so the default spells the path `.`, and a relative path is right
  /// for them. This launcher execs from wherever `flatpak run` leaves it, so a
  /// lone `.` and `${deploy_dir}` both resolve to [prefix] here.
  List<String> _bundleArgs(FlatpakMetadata m, String prefix) {
    final template = m.runCommand ?? defaultRunTemplate;
    if (template.isEmpty) return const [];
    if (!template.first.contains(r'${embedder}')) {
      throw FlatpakPackageException(
        'cross.run.command starts with "${template.first}", which is not the '
        'embedder, so the flatpak launcher cannot reuse it — it execs the '
        'embedder itself. Give cross.package.flatpak.args the bundle flag '
        'with {bundle} in it instead.',
      );
    }
    final expanded = applyRunVars(template.sublist(1), {
      'embedder': m.command,
      'deploy_dir': prefix,
    });
    final out = <String>[];
    for (final raw in expanded) {
      final token = raw == '.' ? prefix : raw;
      // `_validate` walks env and args; it never saw these, and `_shellWord`
      // double-quotes on the assumption something already refused what a
      // double-quoted word cannot hold. `run.command` can come from a board
      // library YAML, so an unchecked token here is command execution inside
      // the sandbox from a file the user did not write.
      _rejectShellBreakout('run.command token', token);
      if (_whitespace.hasMatch(token)) {
        throw FlatpakPackageException(
          'cross.run.command token "$token" contains whitespace; the launcher '
          'passes tokens as shell words, so it would split into several '
          'arguments. Split it into separate list entries.',
        );
      }
      // A leftover `${…}` is a variable `applyRunVars` did not know. Inside the
      // double quotes `_shellWord` may add, the shell would expand it — to
      // nothing, or to something from the sandbox environment.
      if (token.contains(r'${')) {
        throw FlatpakPackageException(
          'cross.run.command token "$token" has an unexpanded variable; the '
          r'launcher knows ${embedder} and ${deploy_dir} only.',
        );
      }
      out.add(_shellWord(token));
    }
    return out;
  }

  /// Reject anything the launcher cannot carry, before a line of it is written.
  void _validate(FlatpakMetadata m) {
    for (final e in m.env.entries) {
      if (!_shellName.hasMatch(e.key)) {
        throw FlatpakPackageException(
          'flatpak env name "${e.key}" is not a shell identifier '
          '(letters, digits and _, not starting with a digit)',
        );
      }
      _rejectShellBreakout('env ${e.key}', e.value);
    }
    for (final a in m.args) {
      _rejectShellBreakout('arg', a);
      if (_whitespace.hasMatch(a)) {
        throw FlatpakPackageException(
          'flatpak arg "$a" contains whitespace; the launcher passes args as '
          'shell words, so it would split into several arguments',
        );
      }
    }
  }

  /// Placeholder for the in-sandbox bundle prefix inside `args`.
  static const _bundleToken = '{bundle}';

  /// A POSIX shell variable name.
  static final _shellName = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$');

  /// A name holding a `:`-separated search path rather than a single value.
  static final _pathShaped = RegExp(r'(PATH|DIRS)$');

  /// Any whitespace, which would split one arg into several shell words.
  static final _whitespace = RegExp(r'\s');

  /// Characters an arg may carry unquoted without the shell reinterpreting it.
  static final _plainWord = RegExp(r'^[A-Za-z0-9_\-=./:,+@%]+$');

  /// [arg] as one shell word: bare when it is plain, else double-quoted so
  /// `'`, `;`, `&`, `|`, redirects and globs stay literal while `$VAR` still
  /// expands. [_rejectShellBreakout] has already refused what a double-quoted
  /// word cannot hold.
  String _shellWord(String arg) => _plainWord.hasMatch(arg) ? arg : '"$arg"';

  /// Write one `env:` entry as a shell assignment.
  ///
  /// Path-shaped names prepend, so the runtime's own entries survive; the rest
  /// are assigned outright. Neither form is a `${NAME:-<value>}` default:
  /// flatpak pre-sets the names worth setting (`LD_LIBRARY_PATH`,
  /// `XDG_DATA_HOME`) before the launcher runs, so a default would never fire.
  void _emitEnv(StringBuffer b, String name, String value) {
    if (_pathShaped.hasMatch(name)) {
      b.writeln('export $name="$value\${$name:+:\$$name}"');
    } else {
      b.writeln('export $name="$value"');
    }
  }

  /// Refuse text that would escape the double-quoted word it is written into,
  /// or run a command when the launcher starts. `$VAR` expansion is the point
  /// of these fields and stays allowed; `"`, backticks and `$(` are not.
  void _rejectShellBreakout(String what, String value) {
    for (final bad in const ['"', r'\', '`', r'$(']) {
      if (value.contains(bad)) {
        throw FlatpakPackageException(
          'flatpak $what value contains "$bad", which the generated launcher '
          'cannot carry safely: $value',
        );
      }
    }
  }

  /// The flatpak-builder manifest (a `simple` module over a `dir` source).
  String _manifest(
    FlatpakMetadata m,
    String prefix,
    String desktopName,
    List<_Extra> extras,
  ) {
    final desktopDest = '/app/share/applications/${m.appId}.desktop';
    final iconDest =
        '/app/share/icons/hicolor/256x256/apps/${m.appId}${_iconExt(m.icon)}';
    // Every manifest-derived value is shell-quoted: flatpak-builder runs each
    // build-command through a shell, so an unquoted `command`, icon extension,
    // mode or destination was a command of the manifest author's choosing
    // running inside the build. `prefix`, `staged` and the appId are emb's own
    // (the appId is pattern-checked above), but quoting them too keeps the rule
    // "nothing here is bare" easy to hold.
    final cmds = <String>[
      'mkdir -p ${_shQuote(prefix)}',
      'cp -r bundle/. ${_shQuote("$prefix/")}',
      'chmod 0755 ${_shQuote("$prefix/${m.command}")}',
      'install -Dm755 launcher.sh ${_shQuote("/app/bin/${m.command}")}',
      _install('644', '${m.appId}.desktop', desktopDest),
      if (m.icon != null)
        _install('644', 'icon${p.extension(m.icon!.path)}', iconDest),
      for (final e in extras) _install(_mode(e.mode), e.staged, e.dest),
    ];
    final b = StringBuffer()
      ..writeln('app-id: ${m.appId}')
      // Pin the app branch so the exported ref matches `build-bundle`'s branch.
      ..writeln('branch: ${m.branch}')
      ..writeln('default-branch: ${m.branch}')
      ..writeln('runtime: ${_yaml(m.runtime)}')
      ..writeln('runtime-version: ${_yaml(m.runtimeVersion)}')
      ..writeln('sdk: ${_yaml(m.sdk)}')
      ..writeln('command: ${_yaml(m.command)}')
      ..writeln('finish-args:');
    for (final a in m.finishArgs) {
      b.writeln('  - ${_yaml(a)}');
    }
    b
      ..writeln('modules:')
      ..writeln('  - name: ${_moduleName(m)}')
      ..writeln('    buildsystem: simple')
      ..writeln('    build-commands:');
    for (final c in cmds) {
      b.writeln('      - ${_yaml(c)}');
    }
    b
      ..writeln('    sources:')
      ..writeln('      - type: dir')
      ..writeln('        path: .');
    return b.toString();
  }

  /// flatpak-builder's module name. It must be an identifier, not a display
  /// name: a space warns, then fails obscurely later. `.desktop` `Name=` keeps
  /// the human string.
  String _moduleName(FlatpakMetadata m) =>
      m.appId.split('.').last.replaceAll(RegExp('[^A-Za-z0-9_-]'), '-');

  String _desktop(FlatpakMetadata m, String name) {
    final b = StringBuffer()
      ..writeln('[Desktop Entry]')
      ..writeln('Type=Application')
      ..writeln('Name=$name')
      ..writeln('Exec=${m.command}')
      ..writeln('Terminal=false')
      ..writeln('Categories=${m.categories.join(';')};');
    if (m.icon != null) b.writeln('Icon=${m.appId}');
    return b.toString();
  }

  /// Normalize an extra-file destination to an absolute `/app/...` path, and
  /// refuse one that climbs out of it. Unnormalized, a `to:` of
  /// `/../../../../etc/evil.conf` produced `/app/../../../../etc/evil.conf`,
  /// which `install` resolves outside the flatpak prefix.
  String _appDest(String dest) {
    final rel = dest.startsWith('/') ? dest.substring(1) : dest;
    final joined = p.posix.normalize(p.posix.join('/app', rel));
    if (joined != '/app' && !p.posix.isWithin('/app', joined)) {
      throw FlatpakPackageException(
        'package file destination escapes /app: $dest',
      );
    }
    return joined;
  }

  /// A file mode for `install -Dm<mode>`, defaulting to 644. Octal only: the
  /// value reaches `install` as part of an argument, so `--reference=…` or any
  /// other option-shaped string would be read as one.
  String _mode(String? mode) {
    if (mode == null) return '644';
    if (!RegExp(r'^[0-7]{3,4}$').hasMatch(mode)) {
      throw FlatpakPackageException(
        'file mode must be 3-4 octal digits, got "$mode"',
      );
    }
    return mode;
  }

  /// A YAML double-quoted scalar. Plain scalars are not safe for values emb
  /// does not control: a ` #` starts a comment (so `command: app #x` silently
  /// became `app`), a `: ` splits a mapping, and a leading `'` or `[` changes
  /// the type. Shell quoting inside survives untouched — single quotes need no
  /// escaping here, only `\` and `"`.
  String _yaml(String v) =>
      '"${v.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"';

  /// One `install -Dm<mode> <src> <dest>` with both paths quoted.
  String _install(String mode, String src, String dest) =>
      'install -Dm$mode ${_shQuote(src)} ${_shQuote(dest)}';

  /// POSIX single-quoting: everything inside is literal, and an embedded quote
  /// is closed, escaped and reopened.
  String _shQuote(String s) => "'${s.replaceAll("'", r"'\''")}'";

  String _iconExt(File? icon) {
    if (icon == null) return '.png';
    final ext = p.extension(icon.path).toLowerCase();
    // hicolor expects `.png` under the sized dir; SVGs belong elsewhere but we
    // keep the basename so at minimum the file is shipped.
    return ext.isEmpty ? '.png' : ext;
  }

  bool _looksLikeAppId(String id) =>
      RegExp(r'^[A-Za-z][\w-]*(\.[A-Za-z][\w-]*){2,}$').hasMatch(id);

  /// Locate [exe] on PATH (`command -v`), or null when absent.
  Future<String?> _which(String exe) async {
    final r = await _run('command', ['-v', exe], runInShell: true);
    if (r.exitCode != 0) return null;
    final out = r.stdout.trim();
    return out.isEmpty ? null : out;
  }

  /// Recursively copy [src] into [dst] via `cp -a` (preserves mode + symlinks).
  Future<void> _copyTree(Directory src, Directory dst) async {
    dst.createSync(recursive: true);
    final r = await _run('cp', [
      '-a',
      '.',
      dst.path,
    ], workingDirectory: src.path);
    if (r.exitCode != 0) {
      throw FlatpakPackageException('copy failed: ${r.stderr}');
    }
  }
}

/// A staged extra file, its destination inside `/app`, and an optional explicit
/// octal mode (null → installed `0644`).
class _Extra {
  _Extra(this.staged, this.dest, this.mode);
  final String staged;
  final String dest;
  final String? mode;
}
