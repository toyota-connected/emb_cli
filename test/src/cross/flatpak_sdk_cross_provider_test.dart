import 'dart:io';

import 'package:emb_cli/src/cross/cross_profile.dart';
import 'package:emb_cli/src/cross/cross_target.dart';
import 'package:emb_cli/src/cross/flatpak_sdk_cross_provider.dart';
import 'package:emb_cli/src/cross/process_runner.dart';
import 'package:emb_cli/src/host/host_info.dart';
import 'package:emb_cli/src/workspace/workspace.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

const _host = HostInfo(
  os: HostOs.linux,
  machineArch: 'x86_64',
  archAliases: {'x86_64', 'x64', 'amd64'},
  hostType: 'fedora',
  versionId: '44',
);

/// glibc's `libc.so` linker script, naming [loader] the way glibc does.
String _libcScript(String libDir, String loader) =>
    '/* GNU ld script */\n'
    'OUTPUT_FORMAT(elf64-x86-64)\n'
    'GROUP ( $libDir/libc.so.6 $libDir/libc_nonshared.a '
    ' AS_NEEDED ( $loader ) )\n';

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('emb_fpsdk_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  /// The SDK's `metadata`, naming [runtime]; and, unless [installed] is
  /// false, that runtime at `<sdk>-runtime` with [libs] in [libDir].
  ///
  /// [spaced] writes `key = value`, as freedesktop's SDK does.
  void pairRuntime(
    Directory sdk,
    String runtime,
    String libDir, {
    List<String> libs = const ['libc.so.6'],
    bool installed = true,
    bool spaced = false,
  }) {
    final eq = spaced ? ' = ' : '=';
    File(p.join(sdk.path, 'metadata')).writeAsStringSync(
      '[Runtime]\nname${eq}sdk\nruntime$eq$runtime\nsdk${eq}sdk\n\n'
      '[Extension x]\nruntime${eq}not/this/one\n',
    );
    if (!installed) return;
    for (final l in libs) {
      File(
        p.join('${sdk.path}-runtime', 'files', libDir, l),
      ).createSync(recursive: true);
    }
  }

  /// The freedesktop SDK's layout: multiarch libdir, `lib64` for the
  /// loader, gcc under `x86_64-unknown-linux-gnu`.
  Directory freedesktopSdk({String name = 'deploy'}) {
    final files = Directory(p.join(tmp.path, name, 'files'));
    Directory(
      p.join(files.path, 'lib/gcc/x86_64-unknown-linux-gnu/15.3.0'),
    ).createSync(recursive: true);
    Directory(p.join(files.path, 'lib64')).createSync(recursive: true);
    Directory(p.join(files.path, 'bin')).createSync(recursive: true);
    File(p.join(files.path, 'lib/x86_64-linux-gnu/libc.so'))
      ..createSync(recursive: true)
      ..writeAsStringSync(
        _libcScript('/usr/lib/x86_64-linux-gnu', '/lib64/ld-linux-x86-64.so.2'),
      );
    pairRuntime(
      files.parent,
      'org.freedesktop.Platform/x86_64/25.08',
      'lib/x86_64-linux-gnu',
      spaced: true,
    );
    return files.parent;
  }

  /// A Yocto-built SDK's layout (meta-flatpak-minimal): plain `lib`, no
  /// `lib64`, gcc under `aarch64-oe-linux`, loader in `/usr/lib`.
  Directory yoctoSdk() {
    final files = Directory(p.join(tmp.path, 'oe', 'files'));
    for (final v in ['9.1.0', '15.3.0', '14.2.0']) {
      Directory(
        p.join(files.path, 'lib/gcc/aarch64-oe-linux/$v'),
      ).createSync(recursive: true);
    }
    File(p.join(files.path, 'lib/libc.so'))
      ..createSync(recursive: true)
      ..writeAsStringSync(
        _libcScript('/usr/lib', '/usr/lib/ld-linux-aarch64.so.1'),
      );
    pairRuntime(
      files.parent,
      'org.flatpak_minimal.Platform/aarch64/wrynose',
      'lib',
    );
    return files.parent;
  }

  /// A fake `flatpak` that knows one installed SDK, and the runtime its
  /// metadata names when that is installed beside it (see [pairRuntime]).
  ProcessRunner flatpak(
    String ref,
    Directory? location, {
    String commit = 'c0ffee',
    List<List<String>>? calls,
  }) {
    return (
      String exe,
      List<String> args, {
      String? workingDirectory,
      Map<String, String>? environment,
      bool includeParentEnvironment = true,
      bool runInShell = false,
      ProcessOutputMode output = ProcessOutputMode.capture,
      String? label,
    }) async {
      calls?.add([exe, ...args]);
      const missing = RunResult(1, '', 'error: not installed');
      if (exe != 'flatpak' || location == null) return missing;
      if (args.last != ref) {
        final rt = FlatpakSdkCrossProvider.runtimeRefOf(
          File(p.join(location.path, 'metadata')),
        );
        final rtDir = Directory('${location.path}-runtime');
        if (args.last != rt || !rtDir.existsSync()) return missing;
        return RunResult(0, '${rtDir.path}\n', '');
      }
      return switch (args[1]) {
        '--show-location' => RunResult(0, '${location.path}\n', ''),
        '--show-commit' => RunResult(0, '$commit\n', ''),
        _ => const RunResult(1, '', ''),
      };
    };
  }

  CrossTarget target({String? triple, Map<String, Object>? flatpakSpec}) =>
      CrossTarget.fromMap({
        'provider': 'flatpak-sdk',
        'triple': ?triple,
        if (flatpakSpec != null)
          'package': {'name': 'app', 'flatpak': flatpakSpec},
      });

  group('sdk_repo', () {
    final haveOstree = () {
      try {
        return Process.runSync('ostree', ['--version']).exitCode == 0;
      } on ProcessException {
        return false;
      }
    }();

    /// Commit the fake freedesktop SDK and its runtime into an archive repo
    /// at [repo], as flatpak tooling publishes them.
    void publish(String repo) {
      final sdk = freedesktopSdk();
      Process.runSync('ostree', ['init', '--repo=$repo', '--mode=archive-z2']);
      for (final (branch, tree) in [
        ('runtime/org.freedesktop.Sdk/x86_64/25.08', sdk.path),
        (
          'runtime/org.freedesktop.Platform/x86_64/25.08',
          '${sdk.path}-runtime',
        ),
      ]) {
        final r = Process.runSync('ostree', [
          'commit',
          '--repo=$repo',
          '--branch=$branch',
          '--subject=test',
          tree,
        ]);
        expect(r.exitCode, 0, reason: '${r.stderr}');
      }
    }

    test(
      'builds from a repo, relative to the manifest, without flatpak',
      skip: haveOstree ? false : 'ostree not installed',
      () async {
        final manifestDir = Directory(p.join(tmp.path, 'project'))
          ..createSync();
        publish(p.join(manifestDir.path, 'repo-dev'));
        final calls = <List<String>>[];
        final pr = FlatpakSdkCrossProvider(
          target(flatpakSpec: {'sdk_repo': 'repo-dev'}),
          workspace: Workspace(tmp),
          host: _host,
          manifestDir: manifestDir,
          cacheDir: Directory(p.join(tmp.path, 'cache')),
          runProcess:
              (
                exe,
                args, {
                workingDirectory,
                environment,
                includeParentEnvironment = true,
                runInShell = false,
                output = ProcessOutputMode.capture,
                label,
              }) {
                calls.add([exe, ...args]);
                return defaultProcessRunner(exe, args);
              },
        );
        expect(pr.preflightTools, contains('ostree'));
        expect(pr.preflightTools, isNot(contains('flatpak')));

        final r = await pr.resolve();
        expect(r.ok, isTrue, reason: r.message);
        expect(calls.map((c) => c.first), everyElement('ostree'));

        final checkouts = p.join(tmp.path, 'cache', 'flatpak-sdk', 'checkouts');
        final pf = r.profile!;
        expect(
          p.isWithin(
            checkouts,
            Link(p.join(pf.targetSysroot, 'usr')).targetSync(),
          ),
          isTrue,
        );
        expect(pf.runtimeLibDirs, everyElement(startsWith(checkouts)));
        final commit = r.lockEntry!.toolchainVersion!.split('@').last;
        expect(commit, matches(RegExp(r'^[0-9a-f]{64}$')));
      },
    );

    test('warns about an unsigned repo URL, and only that', () {
      String? warning(Map<String, Object> spec) => FlatpakSdkCrossProvider(
        target(flatpakSpec: spec),
        workspace: Workspace(tmp),
        host: _host,
      ).unverifiedRepoWarning;
      expect(
        warning({'sdk_repo': 'https://example.com/repo'}),
        contains('without a signature check'),
      );
      expect(
        warning({
          'sdk_repo': 'https://example.com/repo',
          'sdk_repo_gpg_key': 'key.gpg',
        }),
        isNull,
      );
      expect(warning({'sdk_repo': 'repo-dev'}), isNull);
      expect(warning({}), isNull);
    });
  });

  test('the provider token parses', () {
    expect(
      CrossProviderKind.fromToken('flatpak-sdk'),
      CrossProviderKind.flatpakSdk,
    );
    expect(CrossProviderKind.flatpakSdk.token, 'flatpak-sdk');
  });

  group('sdkRef', () {
    test('defaults to the freedesktop SDK for the host arch', () {
      final pr = FlatpakSdkCrossProvider(
        target(),
        workspace: Workspace(tmp),
        host: _host,
      );
      expect(pr.triple, 'x86_64-flatpak-linux-gnu');
      expect(
        pr.sdkRef,
        'org.freedesktop.Sdk/x86_64/$defaultFlatpakRuntimeVersion',
      );
    });

    test('takes the sdk and branch from package.flatpak, arch from the '
        'triple', () {
      final pr = FlatpakSdkCrossProvider(
        target(
          triple: 'aarch64-flatpak-linux-gnu',
          flatpakSpec: {
            'sdk': 'org.flatpak_minimal.Sdk',
            'runtime_version': 'wrynose',
          },
        ),
        workspace: Workspace(tmp),
        host: _host,
      );
      expect(pr.sdkRef, 'org.flatpak_minimal.Sdk/aarch64/wrynose');
    });
  });

  group('resolve', () {
    test('builds against the freedesktop SDK with host clang', () async {
      final sdk = freedesktopSdk();
      final pr = FlatpakSdkCrossProvider(
        target(),
        workspace: Workspace(tmp),
        host: _host,
        runProcess: flatpak('org.freedesktop.Sdk/x86_64/25.08', sdk),
      );
      final r = await pr.resolve();
      expect(r.ok, isTrue, reason: r.message);
      final pf = r.profile!;

      expect(pf.cc, 'clang');
      expect(pf.cxx, 'clang++');
      expect(pf.cFlags, ['--target=x86_64-unknown-linux-gnu']);
      expect(pf.ldFlags, [
        '-fuse-ld=lld',
        '-Wl,--dynamic-linker=/lib64/ld-linux-x86-64.so.2',
      ]);

      // A sysroot of links into the SDK, which is never written to.
      final root = pf.targetSysroot;
      expect(Link(p.join(root, 'usr')).targetSync(), p.join(sdk.path, 'files'));
      expect(Link(p.join(root, 'lib')).targetSync(), 'usr/lib');
      expect(Link(p.join(root, 'lib64')).targetSync(), 'usr/lib64');
      expect(Link(p.join(root, 'sbin')).existsSync(), isFalse);

      expect(pf.pkgConfig!.sysrootDir, root);
      expect(pf.pkgConfig!.libdir, [
        p.join(root, 'usr/lib/x86_64-linux-gnu/pkgconfig'),
        p.join(root, 'usr/lib/pkgconfig'),
        p.join(root, 'usr/share/pkgconfig'),
      ]);

      // Not the host's, not host-runnable, and the SDK is not ours to
      // stage into.
      expect(pf.hostToolchain, isFalse);
      expect(pf.hostRunnable, isFalse);
      expect(pf.separateOverlay, isTrue);

      final lock = r.lockEntry!;
      expect(lock.provider, 'flatpak-sdk');
      expect(lock.toolchainVersion, 'org.freedesktop.Sdk/x86_64/25.08@c0ffee');
      expect(lock.compilerVersion, '15.3.0');
    });

    test('emits toolchain files naming clang, lld and the loader', () async {
      final pr = FlatpakSdkCrossProvider(
        target(),
        workspace: Workspace(tmp),
        host: _host,
        runProcess: flatpak(
          'org.freedesktop.Sdk/x86_64/25.08',
          freedesktopSdk(),
        ),
      );
      final pf = (await pr.resolve()).profile!;

      final cmake = File(pf.cmakeToolchainFile!).readAsStringSync();
      expect(cmake, contains('set(CMAKE_C_COMPILER   "clang")'));
      expect(cmake, contains('set(CMAKE_AR           "llvm-ar")'));
      expect(cmake, contains('set(_xc_sysroot "${pf.targetSysroot}")'));
      expect(cmake, contains('--target=x86_64-unknown-linux-gnu'));
      expect(
        cmake,
        contains(
          'set(CMAKE_SHARED_LINKER_FLAGS_INIT "-fuse-ld=lld '
          '-Wl,--dynamic-linker=/lib64/ld-linux-x86-64.so.2")',
        ),
      );
      // Link flags stay off the compile line.
      expect(
        RegExp('CMAKE_C_FLAGS_INIT.*fuse-ld').hasMatch(cmake),
        isFalse,
      );

      final meson = File(pf.mesonCrossFile!).readAsStringSync();
      expect(meson, contains("c = 'clang'"));
      expect(
        RegExp(r"c_link_args = \[.*'-fuse-ld=lld'").hasMatch(meson),
        isTrue,
      );
      expect(RegExp(r'c_args = \[.*fuse-ld').hasMatch(meson), isFalse);
    });

    test('reads a Yocto-built SDK for another arch', () async {
      final pr = FlatpakSdkCrossProvider(
        target(
          triple: 'aarch64-flatpak-linux-gnu',
          flatpakSpec: {
            'sdk': 'org.flatpak_minimal.Sdk',
            'runtime_version': 'wrynose',
          },
        ),
        workspace: Workspace(tmp),
        host: _host,
        runProcess: flatpak(
          'org.flatpak_minimal.Sdk/aarch64/wrynose',
          yoctoSdk(),
        ),
      );
      final r = await pr.resolve();
      expect(r.ok, isTrue, reason: r.message);
      final pf = r.profile!;
      expect(pf.cFlags, ['--target=aarch64-oe-linux']);
      expect(
        pf.ldFlags,
        contains('-Wl,--dynamic-linker=/usr/lib/ld-linux-aarch64.so.1'),
      );
      expect(pf.pkgConfig!.libdir, [
        p.join(pf.targetSysroot, 'usr/lib/pkgconfig'),
        p.join(pf.targetSysroot, 'usr/share/pkgconfig'),
      ]);
      // No lib64 in this SDK, so no link to a missing dir.
      expect(Link(p.join(pf.targetSysroot, 'lib64')).existsSync(), isFalse);
      // The newest gcc, compared as versions, not strings.
      expect(r.lockEntry!.compilerVersion, '15.3.0');
    });

    test('follows the SDK to its new location after an update', () async {
      const ref = 'org.freedesktop.Sdk/x86_64/25.08';
      final ws = Workspace(tmp);
      final first = freedesktopSdk(name: 'old');
      final a = await FlatpakSdkCrossProvider(
        target(),
        workspace: ws,
        host: _host,
        runProcess: flatpak(ref, first),
      ).resolve();
      final second = freedesktopSdk(name: 'new');
      final b = await FlatpakSdkCrossProvider(
        target(),
        workspace: ws,
        host: _host,
        runProcess: flatpak(ref, second, commit: 'beef'),
      ).resolve();
      expect(b.profile!.targetSysroot, a.profile!.targetSysroot);
      expect(
        Link(p.join(b.profile!.targetSysroot, 'usr')).targetSync(),
        p.join(second.path, 'files'),
      );
      expect(b.lockEntry!.toolchainVersion, '$ref@beef');
    });

    test('cleaning the working dir leaves the SDK alone', () async {
      final sdk = freedesktopSdk();
      final pf = (await FlatpakSdkCrossProvider(
        target(),
        workspace: Workspace(tmp),
        host: _host,
        runProcess: flatpak('org.freedesktop.Sdk/x86_64/25.08', sdk),
      ).resolve()).profile!;
      // What `--clean --all` deletes.
      final dir = Directory(p.dirname(pf.targetSysroot));
      expect(
        p.basename(dir.path),
        startsWith('cross-x86_64-flatpak-linux-gnu-'),
      );
      dir.deleteSync(recursive: true);
      expect(
        File(
          p.join(sdk.path, 'files/lib/x86_64-linux-gnu/libc.so'),
        ).existsSync(),
        isTrue,
      );
    });

    test('points at the runtime the SDK metadata names', () async {
      final sdk = freedesktopSdk();
      final pf = (await FlatpakSdkCrossProvider(
        target(),
        workspace: Workspace(tmp),
        host: _host,
        runProcess: flatpak('org.freedesktop.Sdk/x86_64/25.08', sdk),
      ).resolve()).profile!;
      // The Platform's libdirs, not the SDK's: that is what the app runs on.
      // Plain lib too, for a library kept outside the multiarch dir.
      expect(pf.runtimeLibDirs, [
        p.join('${sdk.path}-runtime', 'files', 'lib/x86_64-linux-gnu'),
        p.join('${sdk.path}-runtime', 'files', 'lib'),
      ]);
    });

    test('says how to install the runtime when only the SDK is', () async {
      final sdk = freedesktopSdk();
      Directory('${sdk.path}-runtime').deleteSync(recursive: true);
      final r = await FlatpakSdkCrossProvider(
        target(),
        workspace: Workspace(tmp),
        host: _host,
        runProcess: flatpak('org.freedesktop.Sdk/x86_64/25.08', sdk),
      ).resolve();
      expect(r.status, CrossResolveStatus.unavailable);
      expect(
        r.message,
        contains(
          'flatpak install flathub org.freedesktop.Platform/x86_64/25.08',
        ),
      );
    });

    test('refuses an SDK whose metadata names no runtime', () async {
      final sdk = freedesktopSdk();
      File(p.join(sdk.path, 'metadata')).writeAsStringSync('[Runtime]\n');
      final r = await FlatpakSdkCrossProvider(
        target(),
        workspace: Workspace(tmp),
        host: _host,
        runProcess: flatpak('org.freedesktop.Sdk/x86_64/25.08', sdk),
      ).resolve();
      expect(r.status, CrossResolveStatus.failed);
      expect(r.message, contains('names no runtime'));
    });

    test('says how to install an SDK that is missing', () async {
      final r = await FlatpakSdkCrossProvider(
        target(),
        workspace: Workspace(tmp),
        host: _host,
        runProcess: flatpak('org.freedesktop.Sdk/x86_64/25.08', null),
      ).resolve();
      expect(r.status, CrossResolveStatus.unavailable);
      expect(
        r.message,
        contains('flatpak install flathub org.freedesktop.Sdk/x86_64/25.08'),
      );
    });

    test('refuses a runtime, which has no compiler', () async {
      // A Platform instead of an Sdk: libraries, no gcc installation.
      final files = Directory(p.join(tmp.path, 'platform', 'files'));
      File(
        p.join(files.path, 'lib/x86_64-linux-gnu/libc.so.6'),
      ).createSync(recursive: true);
      final r = await FlatpakSdkCrossProvider(
        target(),
        workspace: Workspace(tmp),
        host: _host,
        runProcess: flatpak('org.freedesktop.Sdk/x86_64/25.08', files.parent),
      ).resolve();
      expect(r.status, CrossResolveStatus.failed);
      expect(r.message, contains('no x86_64 gcc installation'));
    });

    test('refuses an SDK whose libc.so names no loader', () async {
      final sdk = freedesktopSdk();
      File(
        p.join(sdk.path, 'files/lib/x86_64-linux-gnu/libc.so'),
      ).writeAsStringSync('GROUP ( /usr/lib/libc.so.6 )\n');
      final r = await FlatpakSdkCrossProvider(
        target(),
        workspace: Workspace(tmp),
        host: _host,
        runProcess: flatpak('org.freedesktop.Sdk/x86_64/25.08', sdk),
      ).resolve();
      expect(r.status, CrossResolveStatus.failed);
      expect(r.message, contains('names no ld-linux loader'));
    });

    test('reads a loader with no space before the closing paren', () async {
      final sdk = freedesktopSdk();
      File(
        p.join(sdk.path, 'files/lib/x86_64-linux-gnu/libc.so'),
      ).writeAsStringSync(
        'GROUP ( /usr/lib/x86_64-linux-gnu/libc.so.6 '
        'AS_NEEDED (/lib64/ld-linux-x86-64.so.2))\n',
      );
      final r = await FlatpakSdkCrossProvider(
        target(),
        workspace: Workspace(tmp),
        host: _host,
        runProcess: flatpak('org.freedesktop.Sdk/x86_64/25.08', sdk),
      ).resolve();
      expect(
        r.profile!.ldFlags,
        contains('-Wl,--dynamic-linker=/lib64/ld-linux-x86-64.so.2'),
      );
    });

    test('refuses a loader path it would have to quote', () async {
      // It is written into the CMake and Meson files inside quotes.
      final sdk = freedesktopSdk();
      File(
        p.join(sdk.path, 'files/lib/x86_64-linux-gnu/libc.so'),
      ).writeAsStringSync('GROUP ( AS_NEEDED ( /lib64/ld-linux"x.so ) )\n');
      final r = await FlatpakSdkCrossProvider(
        target(),
        workspace: Workspace(tmp),
        host: _host,
        runProcess: flatpak('org.freedesktop.Sdk/x86_64/25.08', sdk),
      ).resolve();
      expect(r.status, CrossResolveStatus.failed);
      expect(r.message, contains('unexpected loader path'));
    });

    test('fails cleanly when the sysroot cannot be linked', () async {
      final sdk = freedesktopSdk();
      final ws = Workspace(tmp);
      final pr = FlatpakSdkCrossProvider(
        target(),
        workspace: ws,
        host: _host,
        runProcess: flatpak('org.freedesktop.Sdk/x86_64/25.08', sdk),
      );
      final first = (await pr.resolve()).profile!;
      // A real directory where the usr link belongs.
      final usr = p.join(first.targetSysroot, 'usr');
      Link(usr).deleteSync();
      Directory(usr).createSync();
      final r = await pr.resolve();
      expect(r.status, CrossResolveStatus.failed);
      expect(r.message, contains('could not link the sysroot'));
    });

    test('is Linux-only', () async {
      const mac = HostInfo(
        os: HostOs.macos,
        machineArch: 'arm64',
        archAliases: {'arm64'},
        hostType: 'macos',
        versionId: '15',
      );
      final calls = <List<String>>[];
      final r = await FlatpakSdkCrossProvider(
        target(),
        workspace: Workspace(tmp),
        host: mac,
        runProcess: flatpak('x', null, calls: calls),
      ).resolve();
      expect(r.status, CrossResolveStatus.unavailable);
      expect(calls, isEmpty);
    });
  });
}
