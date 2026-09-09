/// Templates for `emb init flatpak` — a self-contained flatpak packaging repo.
///
/// Every generator here is a pure function of a [FlatpakRepoSpec], and the spec
/// is built entirely from command-line flags and the packaged app's own
/// `pubspec.yaml`. Nothing about a particular app, vendor or machine may be
/// baked in: the generated repo has to be correct for an app its author has
/// never seen.
///
/// Templates are inline strings rather than files on disk. `dart install`
/// produces an AOT binary carrying no package data — the board library needs a
/// five-rung resolution ladder and `emb boards sync` to work around exactly
/// that — and every other generator in emb (`env_script.dart`,
/// `dockerfile_emitter.dart`, `toolchain_emitter.dart`) is inline for the same
/// reason.
library;

import 'package:path/path.dart' as p;

/// A reverse-DNS flatpak application id.
///
/// Same rule the packager enforces before it will build, checked here so a
/// generated repo cannot be born unbuildable.
final RegExp flatpakAppIdPattern = RegExp(
  r'^[A-Za-z][\w-]*(\.[A-Za-z][\w-]*){2,}$',
);

/// Everything the generated repo varies on.
///
/// Defaults live on this class, not scattered through the templates, so the
/// full set of assumptions a generated repo carries can be read in one place.
class FlatpakRepoSpec {
  /// Creates a spec. Only [appId] has no sensible default.
  FlatpakRepoSpec({
    required this.appId,
    String? slug,
    String? appName,
    String? summary,
    String? description,
    this.appVersion = '1.0.0',
    this.runtime = 'org.freedesktop.Platform',
    this.runtimeVersion = '25.08',
    this.sdk = 'org.freedesktop.Sdk',
    this.backend = 'wayland-egl',
    this.embedder = 'ivi-homescreen',
    this.appRepo = '',
    this.appRef = '',
    this.homescreenRepo = 'https://github.com/toyota-connected/ivi-homescreen',
    this.homescreenRef = 'main',
    this.flutterVersion = '3.44.2',
    this.flutterChannel = 'stable',
    this.engineVersion = '',
    this.embCliRef = 'main',
    this.hasIcon = false,
  }) : slug = slug ?? _slugFor(appId),
       appName = appName ?? appId.split('.').last,
       summary = summary ?? '${appId.split('.').last}, packaged as a Flatpak',
       description =
           description ??
           'A Flutter application running under $embedder, packaged as a '
               'Flatpak.';

  /// Reverse-DNS app id. Drives the flatpak id, the install prefix, the
  /// `.desktop` and icon basenames, and the AppStream `<id>`.
  final String appId;

  /// Filesystem-safe short name: the manifest basename and its `id:` key.
  final String slug;

  /// Human-readable name, for `package.name` and the AppStream `<name>`.
  final String appName;

  /// One-line AppStream `<summary>`.
  final String summary;

  /// Longer AppStream `<description>` paragraph.
  final String description;

  /// Package version.
  final String appVersion;

  /// Flatpak runtime id, its version, and the matching SDK.
  final String runtime;

  /// Runtime branch, e.g. `25.08`.
  final String runtimeVersion;

  /// SDK id paired with [runtime].
  final String sdk;

  /// Embedder backend to build, e.g. `wayland-egl`.
  final String backend;

  /// Embedder project the app runs under.
  final String embedder;

  /// `owner/name` of the app's own repository, for CI checkout.
  final String appRepo;

  /// Commit SHA of the app to build. A SHA rather than a branch keeps an
  /// unrelated push from drifting into a build.
  final String appRef;

  /// Embedder repository URL and ref.
  final String homescreenRepo;

  /// Embedder git ref.
  final String homescreenRef;

  /// Flutter SDK version and channel `emb flutter` provisions.
  final String flutterVersion;

  /// Flutter channel.
  final String flutterChannel;

  /// Flutter engine commit, when pinned.
  final String engineVersion;

  /// emb_cli ref CI bootstraps.
  final String embCliRef;

  /// Whether an icon file was supplied, and so whether to emit the `icon:` key.
  final bool hasIcon;

  /// In-sandbox install prefix the bundle is copied to.
  String get prefix => '/app/$appId';

  /// Basename of the generated cross manifest.
  String get manifestName => '$slug.emb.yaml';

  /// Basename of the icon, when there is one.
  String get iconName => '$appId.png';

  /// Basename of the AppStream metadata.
  String get appdataName => '$appId.appdata.xml';

  /// A filesystem- and YAML-safe short name derived from an app id's last
  /// segment (`com.example.MyApp` → `myapp`).
  static String _slugFor(String appId) {
    final last = appId.split('.').last;
    final slug = last
        .replaceAllMapped(RegExp('([a-z0-9])([A-Z])'), (m) => '${m[1]}-${m[2]}')
        .toLowerCase()
        .replaceAll(RegExp('[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    return slug.isEmpty ? 'app' : slug;
  }
}

/// The cross manifest: the whole pipeline, declaratively.
///
/// The `finish_args` here are deliberately the narrow Wayland default rather
/// than anything wider. Sandbox permissions are the one field where a generous
/// default is a security bug, so an app that needs more says so explicitly.
String generateEmbManifest(FlatpakRepoSpec s) {
  final b = StringBuffer()
    ..writeln('# Packaging for ${s.appName}, built entirely by emb_cli.')
    ..writeln('#')
    ..writeln(
      '# One `emb cross` invocation builds the embedder, builds the Flutter',
    )
    ..writeln(
      '# app (including any Dart build hooks), assembles the bundle, vendors',
    )
    ..writeln(
      '# what ${s.runtime} does not ship, and emits a single-file .flatpak:',
    )
    ..writeln('#')
    ..writeln(
      '#   emb cross ${s.manifestName} --target local --mode release \\',
    )
    ..writeln('#     --build --app <flutter-app> --flatpak')
    ..writeln('#')
    ..writeln(
      '# The manifest has to sit at the ${s.embedder} source root: '
      '`emb cross <file>`',
    )
    ..writeln(
      "# uses the file's parent directory as the CMake source dir, and "
      'resolves',
    )
    ..writeln(
      '# `icon:`/`files:` against that same directory. scripts/build.sh '
      'stages this',
    )
    ..writeln('# whole directory there.')
    ..writeln('id: ${s.slug}')
    ..writeln('type: app')
    ..writeln('supported_archs: [arm64, x86_64]')
    ..writeln('supported_host_types: [ubuntu, fedora]')
    ..writeln()
    ..writeln('cross:')
    ..writeln(
      '  provider: arm-gnu              '
      '# required to parse; ignored for --target local',
    )
    ..writeln('  defines:')
    ..writeln("    DISABLE_PLUGINS: 'ON'");

  if (s.embedder == 'ivi-homescreen') {
    b
      ..writeln(
        '    # agl_shell may only be bound by one client, and on an AGL image '
        'the',
      )
      ..writeln(
        '    # launcher already owns it — binding it aborts the whole '
        'connection.',
      )
      ..writeln(
        '    # An app running alongside a launcher compiles that client out '
        'and',
      )
      ..writeln('    # uses plain xdg-shell instead.')
      ..writeln("    ENABLE_AGL_SHELL_CLIENT: 'OFF'")
      ..writeln("    ENABLE_XDG_CLIENT: 'ON'");
  }

  b
    ..writeln('  backends:')
    ..writeln(
      '    # One backend keeps the app id unsuffixed and the runnable dir '
      'plain',
    )
    ..writeln('    # `runnable/`. A second backend is one more entry here.')
    ..writeln('    ${s.backend}:')
    ..writeln("      ${_backendDefine(s.backend)}: 'ON'");
  for (final off in _backendsToDisable(s.backend)) {
    b.writeln("      $off: 'OFF'");
  }

  b
    ..writeln()
    ..writeln('  package:')
    ..writeln('    name: ${s.appName}')
    ..writeln('    version: ${s.appVersion}')
    ..writeln('    bin: ${_binFor(s.embedder)}')
    ..writeln(
      '    # No `files:` entry for the appdata. It is kept beside this '
      'manifest as',
    )
    ..writeln(
      "    # the app's metadata of record, but installing it into "
      '/app/share/metainfo',
    )
    ..writeln(
      '    # makes flatpak-builder run appstream-compose, which the '
      'freedesktop SDK',
    )
    ..writeln('    # does not ship — the build fails.')
    ..writeln('    flatpak:')
    ..writeln('      app_id: ${s.appId}')
    ..writeln('      runtime: ${s.runtime}')
    ..writeln("      runtime_version: '${s.runtimeVersion}'")
    ..writeln('      sdk: ${s.sdk}');

  if (s.hasIcon) {
    b.writeln('      icon: ${s.iconName}');
  } else {
    b
      ..writeln('      # Drop a PNG beside this manifest and uncomment to ship')
      ..writeln('      # an icon in the hicolor theme:')
      ..writeln('      # icon: ${s.iconName}');
  }

  b
    ..writeln('      categories: [Utility]')
    ..writeln(
      "      # The runtime is not the sysroot: emb walks the bundle's "
      'DT_NEEDED',
    )
    ..writeln(
      '      # closure, subtracts what the runtime provides, and copies the '
      'rest',
    )
    ..writeln(
      r"      # into lib/, where the bundle's $ORIGIN/lib rpath already looks.",
    )
    ..writeln('      vendor_libs: auto')
    ..writeln('      env:')
    ..writeln(
      '        # The launcher exports these unconditionally; flatpak pre-sets '
      'both',
    )
    ..writeln(
      '        # LD_LIBRARY_PATH and XDG_DATA_HOME, so a default would never '
      'fire.',
    )
    ..writeln(
      "        # Names ending in PATH/DIRS prepend, so the runtime's own "
      'entries',
    )
    ..writeln(
      '        # survive. For a value a user should be able to override, use '
      'a',
    )
    ..writeln('        # finish-args `--env=NAME=VALUE` instead.');

  if (s.embedder == 'ivi-homescreen') {
    b.writeln('        IHS_LOG_LEVEL: info');
  }

  b
    ..writeln(
      "        # Dart dlopen()s a build hook's code assets by bare soname, so "
      'they',
    )
    ..writeln(
      r'        # carry no DT_NEEDED entry. $ORIGIN/lib covers the linked '
      'case; this',
    )
    ..writeln('        # covers the dlopen one, from a caller with no rpath.')
    ..writeln('        LD_LIBRARY_PATH: ${s.prefix}/lib')
    ..writeln(
      '        # glib otherwise asks xdg-desktop-portal for proxy config; '
      'with no',
    )
    ..writeln(
      '        # portal running that blocks for the full D-Bus timeout at '
      'startup.',
    )
    ..writeln('        GIO_USE_PROXY_RESOLVER: dummy')
    ..writeln(r'        XDG_DATA_HOME: $HOME/.local/share')
    ..writeln('      args:');

  if (s.embedder == 'ivi-homescreen') {
    b
      ..writeln('        - --backend=${s.backend}')
      ..writeln('        - --shell=xdg')
      ..writeln('        - --app-id=${s.appId}');
  } else {
    b
      ..writeln('        # Embedder flags describing this app. If the embedder')
      ..writeln('        # spells the bundle path itself, write {bundle} into')
      ..writeln('        # an arg and emb drops its default `-b <prefix>`.')
      ..writeln('        []');
  }

  b
    ..writeln('      finish_args:')
    ..writeln(
      '        # The narrowest sandbox that runs a Wayland Flutter shell. '
      'Widen it',
    )
    ..writeln(
      '        # deliberately — every line here is a permission the app keeps '
      'for',
    )
    ..writeln('        # as long as it is installed.')
    ..writeln('        - --share=ipc')
    ..writeln('        - --socket=wayland')
    ..writeln('        - --device=dri');
  return b.toString();
}

/// The CMake option that turns [backend] on.
String _backendDefine(String backend) =>
    'BUILD_BACKEND_${backend.replaceAll('-', '_').toUpperCase()}';

/// The default-on backends to switch off, so exactly one backend is built.
/// Skips whichever one is being enabled.
List<String> _backendsToDisable(String backend) => [
  for (final other in const ['wayland-egl', 'wayland-vulkan'])
    if (other != backend) _backendDefine(other),
];

/// Path of the embedder binary inside a backend's build dir.
String _binFor(String embedder) =>
    embedder == 'ivi-homescreen' ? 'shell/homescreen' : 'shell/$embedder';

/// The embedder's source manifest, consumed by `emb sync`.
///
/// This is where the embedder revision is pinned, and the only place: the local
/// build and CI both clone through `emb sync -p emb-src`, so there is no second
/// copy in `versions.env` to drift out of step with it.
///
/// `emb sync -p <dir>` discovers packages by walking <dir>'s *subdirectories*
/// for an `emb.yaml`, so the extra nesting is required — a loose
/// `<name>.emb.yaml` at the top of the directory is silently skipped.
String generateEmbedderSrcManifest(FlatpakRepoSpec s) =>
    '''
# Where the embedder source comes from. `scripts/build.sh` runs
#
#   emb sync -p emb-src -w <workspace>
#
# which clones this into <workspace>/app/${s.embedder}. This is the only place
# the embedder revision is written; nothing else references it.
#
# A `branch:` tracks a moving target — every build may get a different tree.
# Replace it with `rev: <40-char sha>` once you know which commit you want, so
# a rebuild months from now produces the same embedder.
id: ${s.embedder}-src
type: app
src:
  - uri: ${s.homescreenRepo}${s.homescreenRepo.endsWith('.git') ? '' : '.git'}
    ${_srcRef(s.homescreenRef)}
    submodules: true
''';

/// Render a git ref as the manifest key that honestly describes it.
///
/// A 40-character hex sha is a pin and belongs under `rev:`; anything else is a
/// branch or tag that moves, and calling it `rev:` would dress a moving target
/// up as a reproducible one.
String _srcRef(String ref) =>
    RegExp(r'^[0-9a-f]{7,40}$').hasMatch(ref) ? 'rev: $ref' : 'branch: $ref';

/// `scripts/build.sh` — staging only; emb does the work.
String generateBuildScript(FlatpakRepoSpec s) =>
    '''
#!/usr/bin/env bash
# Build the flatpak. One emb invocation runs the whole pipeline; everything here
# stages its inputs.
set -euo pipefail

: "\${APP_DIR:?must be set - path to the Flutter app checkout}"
EMB_TARGET="\${EMB_TARGET:-local}"
EMB_MODE="\${EMB_MODE:-release}"

PKG_DIR="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST=${s.manifestName}

[[ -d "\$APP_DIR" ]] || { echo "ERROR: not a directory: \$APP_DIR" >&2; exit 1; }

command -v emb >/dev/null || {
  echo "ERROR: emb (emb_cli) not found on PATH - bootstrap it first (see README)" >&2
  exit 1
}

# emb reuses any engine artifacts it finds in a workspace, and an engine from an
# unrelated SDK silently mismatches gen_snapshot and dies at Dart VM init. Pin
# the workspace to ours rather than inheriting one.
if [[ -n "\${FLUTTER_WORKSPACE:-}" && "\$FLUTTER_WORKSPACE" != "\$PKG_DIR/staging/emb-workspace" ]]; then
  echo "NOTE: ignoring inherited FLUTTER_WORKSPACE=\$FLUTTER_WORKSPACE" >&2
fi
export FLUTTER_WORKSPACE="\$PKG_DIR/staging/emb-workspace"

if [[ ! -x "\$FLUTTER_WORKSPACE/flutter/bin/flutter" ]]; then
  echo "ERROR: no Flutter SDK in \$FLUTTER_WORKSPACE - run first:" >&2
  echo "  FLUTTER_WORKSPACE=\$FLUTTER_WORKSPACE emb flutter --flutter-version <version>" >&2
  exit 1
fi

# setup_env.sh scopes PUB_CACHE and XDG_CONFIG_HOME to the workspace, so a build
# does not reach into the user's global pub cache. It bakes an absolute
# FLUTTER_WORKSPACE, though, so a copy of this repo would inherit whichever
# workspace it was generated against — regenerate it for ours before sourcing.
emb env -w "\$FLUTTER_WORKSPACE" >/dev/null
# shellcheck disable=SC1091
. "\$FLUTTER_WORKSPACE/setup_env.sh" >/dev/null

# A freshly provisioned SDK is a git checkout with no bin/cache: the Dart SDK
# and engine artifacts only appear once a flutter command runs. emb decides
# which frontend_server to use by probing that cache *before* it invokes
# flutter, so on a cold workspace it takes the wrong branch and the kernel
# snapshot fails. Warm the cache first; it is a no-op once populated.
if [[ ! -f "\$FLUTTER_WORKSPACE/flutter/bin/cache/dart-sdk/bin/snapshots/frontend_server_aot.dart.snapshot" ]]; then
  echo "Precaching Flutter artifacts (first build in this workspace)..."
  "\$FLUTTER_WORKSPACE/flutter/bin/flutter" precache --linux --no-universal
fi

# The embedder source. emb-src/ pins the revision; emb sync clones it into
# <workspace>/app. Set IHS_DIR yourself to build against your own checkout.
if [[ -z "\${IHS_DIR:-}" ]]; then
  emb sync -p "\$PKG_DIR/emb-src" -w "\$FLUTTER_WORKSPACE"
  IHS_DIR="\$FLUTTER_WORKSPACE/app/${s.embedder}"
fi
[[ -d "\$IHS_DIR" ]] || { echo "ERROR: not a directory: \$IHS_DIR" >&2; exit 1; }

# emb does not resolve the app itself — it expects a package_config.json and
# says so. This repo scopes PUB_CACHE to its own workspace, so an app that was
# resolved anywhere else carries a config pointing at packages this cache does
# not hold, which surfaces as type errors inside Flutter's own sources.
"\$FLUTTER_WORKSPACE/flutter/bin/flutter" pub get --directory "\$APP_DIR"

# The manifest names the CMake source dir by its own location, and resolves
# `icon:`/`files:` against it, so the whole emb/ directory goes to the
# ${s.embedder} root.
cp -a "\$PKG_DIR/emb/." "\$IHS_DIR/"

cd "\$IHS_DIR"
emb cross "\$MANIFEST" \\
  --target "\$EMB_TARGET" \\
  --mode "\$EMB_MODE" \\
  --build \\
  --app "\$APP_DIR" \\
  --flatpak

# emb writes the bundle to <build-root>/dist/. Collect it where CI and a local
# `flatpak install` can both find it without knowing emb's build-dir hash.
mkdir -p "\$PKG_DIR/dist"
find "\$FLUTTER_WORKSPACE/.config/flutter_workspace" -path '*/dist/*.flatpak' \\
  -exec cp -a {} "\$PKG_DIR/dist/" \\;
ls -lh "\$PKG_DIR/dist"
''';

/// `versions.env` — every pin CI loads into `$GITHUB_ENV`.
String generateVersionsEnv(FlatpakRepoSpec s) =>
    '''
FLATPAK_RUNTIME_VERSION=${s.runtimeVersion}

FLUTTER_VERSION=${s.flutterVersion}
FLUTTER_CHANNEL=${s.flutterChannel}
${s.engineVersion.isEmpty ? '' : '\nFLUTTER_ENGINE_VERSION=${s.engineVersion}\n'}
# The app to package. A commit SHA rather than a branch, so an unrelated push
# cannot drift into a build.
APP_REPO=${s.appRepo}
APP_REF=${s.appRef}

# The embedder revision is pinned in emb-src/${s.embedder}-src/emb.yaml, which
# `emb sync` reads — deliberately not duplicated here.
EMB_CLI_REF=${s.embCliRef}
EMB_TARGET=local
''';

/// AppStream metadata. Generated but deliberately not installed — see the
/// manifest comment.
String generateAppdata(FlatpakRepoSpec s) =>
    '''
<?xml version="1.0" encoding="UTF-8"?>
<component type="desktop-application">
  <id>${s.appId}</id>
  <metadata_license>CC0-1.0</metadata_license>
  <project_license>FIXME</project_license>
  <name>${_xml(s.appName)}</name>
  <summary>${_xml(s.summary)}</summary>
  <description>
    <p>
      ${_xml(s.description)}
    </p>
  </description>
  <launchable type="desktop-id">${s.appId}.desktop</launchable>
  <releases>
    <release version="${s.appVersion}" />
  </releases>
</component>
''';

/// Escape the five XML metacharacters in generated text.
String _xml(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&apos;');

/// `.gitignore` — exactly what the pipeline produces, nothing more.
String generateGitignore() => '''
# Everything the pipeline produces. emb owns staging/ (workspace, engine, build
# trees); scripts/build.sh collects the bundle into dist/.
staging/
dist/
*.flatpak
''';

/// The composite action that provisions emb_cli and the embedder checkout.
/// Carries no app-specific value — everything comes from `versions.env`.
String generateBuildEmbedderAction(FlatpakRepoSpec s) =>
    '''
name: "Set up emb_cli and ${s.embedder}"
description: >
  Installs host build dependencies and bootstraps toyota-connected/emb_cli. The
  build itself is scripts/build.sh, which clones the embedder with `emb sync`
  (pinned in emb-src/), stages this repo's emb/ manifest into it, and runs a
  single `emb cross --build --app --flatpak`.

  Dependencies are installed with apt rather than `emb deps`, because emb's
  package backend is PackageKit and hosted runners have no PackageKit daemon.

inputs:
  emb-cli-ref:
    description: "git ref of toyota-connected/emb_cli to bootstrap"
    required: true

runs:
  using: "composite"
  steps:
    - name: Install host build dependencies
      shell: bash
      run: |
        set -euo pipefail
        sudo apt-get update -qq
        sudo apt-get install -yq --no-install-recommends \\
          pkg-config libegl-dev libgles2-mesa-dev libdrm-dev libgbm-dev \\
          libinput-dev libxkbcommon-dev libwayland-dev wayland-protocols \\
          libudev-dev libasio-dev libglib2.0-dev \\
          libpugixml-dev libseat-dev libdisplay-info-dev libxcursor-dev \\
          elfutils

    - name: Bootstrap emb_cli
      shell: bash
      run: |
        set -euo pipefail
        git clone --depth 1 --branch "\${{ inputs.emb-cli-ref }}" \\
          https://github.com/toyota-connected/emb_cli.git "\${{ github.workspace }}/emb_cli"
        eval "\$("\${{ github.workspace }}/emb_cli/bootstrap.sh" --shellenv)"
        command -v emb
        dirname "\$(command -v emb)" >> "\$GITHUB_PATH"

''';

/// The one CI workflow: build natively per arch, upload, deploy, release.
String generateCiWorkflow(FlatpakRepoSpec s) =>
    '''
name: ci

# One workflow, because there is one build. emb cross produces the .flatpak
# directly, so there is no intermediate artifact to publish and no checksum to
# pin back into a manifest.
on:
  push:
    branches: [main]
    tags: ['v*']
  pull_request:
  workflow_dispatch: {}

jobs:
  flatpak:
    name: "Flatpak (\${{ matrix.arch }})"
    strategy:
      fail-fast: false
      matrix:
        include:
          - arch: x86_64
            runner: ubuntu-latest
          - arch: aarch64
            runner: ubuntu-24.04-arm
    runs-on: \${{ matrix.runner }}
    steps:
      - name: Checkout this repo
        uses: actions/checkout@v5

      - name: Load versions.env
        # \$GITHUB_ENV parses KEY=value only — a comment line fails the step
        # with "Invalid format", so strip comments and blanks on the way in.
        run: grep -Ev '^[[:space:]]*(#|\$)' versions.env >> "\$GITHUB_ENV"

      - name: Checkout the app at pinned ref
        uses: actions/checkout@v5
        with:
          repository: \${{ env.APP_REPO }}
          ref: \${{ env.APP_REF }}
          path: app
          fetch-depth: 1
          persist-credentials: false

      - name: Set up emb_cli
        uses: ./.github/actions/build-embedder
        with:
          emb-cli-ref: \${{ env.EMB_CLI_REF }}

      - name: Provision Flutter SDK
        env:
          FLUTTER_WORKSPACE: \${{ github.workspace }}/staging/emb-workspace
        run: |
          mkdir -p "\$FLUTTER_WORKSPACE"
          emb flutter --flutter-version "\${{ env.FLUTTER_VERSION }}"

      # emb needs flatpak-builder to build the bundle, and the runtime itself to
      # know which libraries it already provides (package.flatpak.vendor_libs).
      - name: Install flatpak-builder and the runtime
        run: |
          set -euo pipefail
          sudo apt-get update -qq
          sudo apt-get install -yq --no-install-recommends flatpak flatpak-builder
          flatpak remote-add --if-not-exists --user flathub \\
            https://dl.flathub.org/repo/flathub.flatpakrepo
          flatpak install --user -y --noninteractive \\
            "${s.runtime}//\${{ env.FLATPAK_RUNTIME_VERSION }}" \\
            "${s.sdk}//\${{ env.FLATPAK_RUNTIME_VERSION }}"

      - name: Build the flatpak
        env:
          APP_DIR: \${{ github.workspace }}/app
          EMB_TARGET: \${{ env.EMB_TARGET }}
        run: ./scripts/build.sh

      - name: Upload bundle artifact
        uses: actions/upload-artifact@v4
        with:
          name: flatpak-\${{ matrix.arch }}
          path: dist/*.flatpak

      - name: Deploy to flat-manager
        if: github.event_name == 'push' && github.ref == 'refs/heads/main'
        continue-on-error: true
        uses: flatpak/flatpak-github-actions/flat-manager@v6
        with:
          repository: \${{ vars.FLAT_MANAGER_REPOSITORY }}
          flat-manager-url: \${{ secrets.FLAT_MANAGER_URL }}
          token: \${{ secrets.FLAT_MANAGER_TOKEN }}

  release:
    needs: flatpak
    if: github.ref_type == 'tag'
    runs-on: ubuntu-latest
    permissions:
      contents: write
    steps:
      - uses: actions/download-artifact@v4
        with:
          pattern: flatpak-*
      - name: Create release
        env:
          GH_TOKEN: \${{ github.token }}
        run: |
          gh release create "\${{ github.ref_name }}" \\
            flatpak-x86_64/*.flatpak \\
            flatpak-aarch64/*.flatpak \\
            --generate-notes
''';

/// The README, written for someone who did not run the generator.
String generateReadme(FlatpakRepoSpec s) =>
    '''
# ${s.appName}

Flatpak packaging for ${s.appName}. It runs under ${s.embedder} rather than
Flutter's own Linux runner, because that is what the target hardware uses.

Everything is built by [emb_cli](https://github.com/toyota-connected/emb_cli).
One `emb cross` invocation builds the embedder, builds the app (including any
Dart build hooks), assembles the bundle, vendors the libraries the runtime does
not provide, and emits the `.flatpak`. This repo contributes a manifest and the
metadata; it does not assemble anything itself.

Generated by `emb init flatpak`.

## Build

```sh
sudo apt install flatpak flatpak-builder

# emb on PATH
git clone https://github.com/toyota-connected/emb_cli
eval "\$(emb_cli/bootstrap.sh --shellenv)"

# the Flutter SDK, into this repo's workspace
FLUTTER_WORKSPACE=\$PWD/staging/emb-workspace emb flutter \\
  --flutter-version ${s.flutterVersion}

# the runtime, which emb also reads to decide what needs vendoring
flatpak install --user ${s.runtime}//${s.runtimeVersion} ${s.sdk}//${s.runtimeVersion}

export APP_DIR=/path/to/the/flutter/app
./scripts/build.sh

flatpak install --user dist/*.flatpak
flatpak run ${s.appId}
```

Anything unset stops the build with a message naming it.

`scripts/build.sh` is only staging. It pins `FLUTTER_WORKSPACE` to
`staging/emb-workspace`, sources the `setup_env.sh` that `emb env` writes there
(which scopes `PUB_CACHE` and `XDG_CONFIG_HOME` to the workspace), clones the
embedder with `emb sync` unless you set `IHS_DIR` to a checkout of your own,
resolves the app with `flutter pub get` against that workspace cache, copies
`emb/` into the ${s.embedder} checkout, and runs:

```sh
emb cross ${s.manifestName} --target local --mode release \\
  --build --app "\$APP_DIR" --flatpak
```

The copy is not incidental: `emb cross <file>` uses the file's parent directory
as the CMake source dir, and resolves `icon:`/`files:` against that same
directory, so the manifest and its assets have to sit at the source root.

## The manifest

`emb/${s.manifestName}` holds the whole pipeline — embedder defines, the backend
matrix, and a `cross.package.flatpak` block carrying the app id, runtime, sandbox
permissions, launcher environment and embedder flags. There is no
flatpak-builder manifest here; emb generates one.

Scaling is by adding entries, not scripts: another backend is one more key under
`backends:`, another board is a `cross.targets:` entry, and app-specific `-dev`
packages belong in the app's own `.emb/*.emb.yaml`, which `--app` merges over the
target.

### Sandbox permissions

`finish_args` starts at the narrowest set that runs a Wayland Flutter shell:
`--share=ipc`, `--socket=wayland`, `--device=dri`. Add what the app genuinely
needs — `--share=network`, a D-Bus name, a filesystem path — one line at a time.
Each is a permission the app keeps for as long as it is installed.

## CI

`ci.yml` runs on pushes to `main`, on tags, on pull requests, and on demand. It
builds natively per arch — x86_64 on `ubuntu-latest`, aarch64 on
`ubuntu-24.04-arm` — and uploads the `.flatpak` from each. There is no
intermediate artifact and no checksum to pin: the build that produces the bundle
is the build that publishes it.

Deploying to flat-manager happens only from `main`; releases only on tags.
Branches and PRs build and stop. It needs secrets `FLAT_MANAGER_URL` and
`FLAT_MANAGER_TOKEN` plus variable `FLAT_MANAGER_REPOSITORY`; until those exist
the step fails, and `continue-on-error` keeps it from blocking the rest.

`versions.env` holds the pins and is loaded into `\$GITHUB_ENV`. Fill in
`APP_REPO` and `APP_REF` before CI can check the app out. The embedder revision
is not there — it is pinned in `emb-src/${s.embedder}-src/emb.yaml`, which
`emb sync` reads for both local builds and CI, so there is only one copy to
bump.

## Debugging

```sh
flatpak run --command=sh -li ${s.appId}
APP=${s.prefix}
readelf -d \$APP/${p.basename(_binFor(s.embedder))} | grep RPATH   # \$ORIGIN/lib:\$ORIGIN
ldd \$APP/${p.basename(_binFor(s.embedder))} | grep 'not found'
```

An empty `not found` is the check that vendoring did its job — though it will
not catch `dlopen`ed libraries, which carry no `DT_NEEDED` entry. Those resolve
through the `LD_LIBRARY_PATH` the launcher sets.

## Gotchas

The appdata file is shipped in `emb/` but deliberately not installed: putting it
in `/app/share/metainfo` makes flatpak-builder run `appstream-compose`, which the
freedesktop SDK does not have, and the build fails.

`XDG_DATA_HOME` in the manifest's `env:` block matters for any app that reads
per-user data through a library that consults it — without it, the library sees
Flatpak's private per-app data dir instead of the user's. The launcher is the
only place that can set it: flatpak forces the `XDG_*_HOME` variables after the
user environment, so `flatpak run --env=XDG_DATA_HOME=…` is ignored.

`LD_LIBRARY_PATH` is likewise always `/app/lib` in the sandbox, so the entry
prepends the bundle's `lib/` rather than replacing it — that is what puts a
`dlopen`ed, bare-soname library within reach without hiding the runtime's own.

The system libraries come from the runner's `/usr/lib`, not a target sysroot, so
CI and local dev may not ship identical versions.
''';
