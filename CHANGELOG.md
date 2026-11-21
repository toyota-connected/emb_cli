# Unreleased

New entries go here, not under the heading below. The pubspec reads
`0.7.0-dev`, and nobody can tell whether work recorded under a published
version shipped.

**Flatpak.**

- feat(cross): a `flatpak-sdk` target whose `sdk_repo` cannot be pulled
  builds from the cache. An unreachable server or a dropped connection failed
  the build even with a usable commit cached. emb now uses the commit that
  repo last served and warns that it may be stale. With nothing cached it
  still fails. A commit cached under `sdk_repo_gpg_key` was verified when it
  was pulled, and `emb.lock` still flags drift from a pinned commit.

- fix(cross): an `sdk_repo` pull could hang a build indefinitely. It is now
  killed after 30 minutes and handled as a failed pull. With libcurl, OSTree
  already aborts a stalled transfer itself; the limit covers older OSTree,
  its other HTTP backend and a hung local filesystem.

# 0.6.0

Released from `main`. The headline is the `flatpak-sdk` cross provider: a
flatpak built against the runtime's own SDK, not the build host, so it starts
on the runtime it names. Upgrading from 0.5.x needs the notes below.

## Upgrading

**The `flatpak-sdk` provider needs LLVM on the build host.** It compiles with
the host's `clang` and links with `lld`, using `llvm-ar`, `llvm-strip` and
`llvm-readelf`. `sdk_repo:` also needs the OSTree command-line tool. Other
providers do not need either, and `emb doctor` reports what is missing.

**A native `--flatpak` build no longer lets an augment's `find_package`
reach the host.** With `--target local --flatpak`, a CMake augment's
config-mode `find_package` now searches only the augment overlay. An augment
that found a dependency in the host's `/usr`, and did not bundle its own copy,
now fails to configure. Before, it linked a library the runtime does not ship.
To keep the host package, set `CMAKE_FIND_ROOT_PATH_MODE_PACKAGE: BOTH` in that
augment's `defines:`. Builds without `--flatpak`, and cross builds, are
unchanged.

**A cross target's `triple:` must be a plain token.** It may hold only
`A-Z a-z 0-9 . _ -`. Every real triple does; a value with a `/` now stops the
build with the reason, where before it named directories outside the
workspace.

**Cross.**

- fix(cross): refuse a `triple:` that would leave the workspace. It names
  `cross-<triple>-…`, `overlay-<triple>` and `cross-build-<triple>-…`, which
  `--clean` deletes recursively, so `triple: x/../../../y` aimed both the
  writes and the deletes outside it. It is checked when the manifest loads,
  for every provider, as an augment's `pkg` and `min` already are. A
  yocto-sdk target without `triple:` takes it from the SDK's
  `OECORE_TARGET_ARCH`/`OECORE_TARGET_OS`; that one is checked when resolved.

**Flatpak.**

- feat(cross): a `flatpak-sdk` target can take its SDK from an OSTree repo
  (#335). `package.flatpak.sdk_repo:` names one, as a URL or a path relative
  to the manifest: a Yocto build's `repo-dev`, or another architecture's SDK,
  with no `flatpak install`. emb pulls the SDK and its runtime into one
  `bare-user` repo in its cache and checks each commit out once, hard-linked.
  `sdk_repo_gpg_key:` requires signed commits; a URL without one is pulled
  with a warning. `--offline` uses the cached commit, `emb fetch` pulls ahead,
  and `emb.lock` pins the commit. Needs the OSTree command-line tool on the host.

- feat(cross): a `flatpak-sdk` build skips an augment only when the runtime
  has its libraries too (#335). The SDK ships libraries its runtime does not
  (pkgconf in freedesktop's; curl, systemd, uuid in a Yocto-built one), and an
  augment the SDK satisfied was skipped, so the app linked a library that was
  not there at run time. The provider now locates the runtime the SDK's
  `metadata` names and the augment check asks it too, following
  `lib<name>.so` to the soname the runtime ships. An augment built for this
  reason says so.

- feat(cross): a `flatpak-sdk` provider builds against the runtime's SDK
  rather than the host (#335). A host newer than the runtime built a flatpak
  that would not start: firebase_ffi's demo needed `GLIBC_2.43` on a 25.08
  runtime with 2.42. The installed `<sdk>/<arch>/<runtime_version>` becomes
  the sysroot, and the host clang compiles against its glibc and libstdc++,
  linking with lld. The gcc triple, library directory and loader are read from
  the SDK, so a Yocto-built SDK works as well as freedesktop's, and `triple:`
  selects another architecture's SDK. `emb.lock` records the SDK commit.
  Augments go to a separate overlay, which a cross toolchain now names as a
  find root. See [Building against the flatpak SDK](README.md#building-against-the-flatpak-sdk).

- fix(flatpak): a native `--flatpak` build linked host libraries the runtime
  does not ship (#335). With no toolchain file, a CMake augment's config-mode
  `find_package` searched the host's `/usr`. firebase_ffi's SDK found Fedora's
  abseil there and linked about 100 abseil libraries. For `--target local
  --flatpak`, augments now configure with `CMAKE_FIND_ROOT_PATH` set to the
  overlay and `CMAKE_FIND_ROOT_PATH_MODE_PACKAGE=ONLY`, as a cross toolchain
  file already does. Module-mode finds and pkg-config are unchanged, and an
  augment's own `defines:` can override the mode. See Upgrading.

- fix(flatpak): the symbol-version check for `vendor_libs` could read the
  build host's library in place of the runtime's. Since 0.5.1 a runtime
  soname symlink counts as provided, and the check read the link on the build
  host. An absolute target (`/usr/lib/...`) names the runtime's file inside
  the sandbox, where the runtime is `/usr`, but the host's own file outside it,
  so a gap could be missed or invented. The link is now followed inside the
  runtime, with `/usr` and `/lib` mapped to its root. A link that dangles or
  leaves the runtime still counts as provided, and its versions read as
  unknown.

# 0.5.1

Released from `main`, which holds 0.5.0 plus the two fixes below and nothing
else.

## Upgrading

Rebuild any flatpak that sets `vendor_libs`. A 0.5.0 bundle carries the build
host's copies of libraries the runtime already ships, and those copies take
precedence over the runtime's. The rebuilt bundle vendors only what the
runtime lacks. Nothing else needs a change.

**Flatpak.**

- fix(flatpak): `vendor_libs` copied the build host's copy of nearly every
  library the runtime ships into the bundle. It indexed only the runtime's
  regular files, and a soname is nearly always a symlink to the versioned
  file (`libEGL.so.1 -> libEGL.so.1.0.0`), so those libraries counted as
  missing. The copies come first on the launcher's `LD_LIBRARY_PATH` and
  shadow the runtime's: a bundle for `org.freedesktop.Platform//25.08` carried
  the host's libEGL, libGLESv2, libgbm and libwayland-client, and aborted on a
  Raspberry Pi 5 with `Failed to choose EGL config`. Soname links now count as
  provided; that bundle vendors 22 libraries instead of 72.

**Docs.**

- fix(docs): three doc comments had a code span wrapped across lines, so
  the doc generator read `<pkg>`, `<image>` and `<embArgs>` as HTML tags. This cost
  0.5.0 10 pub points for static analysis. The
  `unintended_html_in_doc_comment` lint is now on, so CI catches the next one.

# 0.5.0

Released from `main`, which is what CI validates. Upgrading from 0.4.x needs
the notes below. Upgrading from 0.3.x needs the Upgrading section under 0.4.0
as well.

## Upgrading

These change what an existing manifest, script or CI job gets. The first two
can fail a build that passes on 0.4.1.

**A project that builds more than one executable must set
`cross.package.bin`.** With it unset, emb took the first ELF file with an
execute bit, which could be a shared library, in filesystem order. It now takes
programs only, and stops with the list when there is more than one. A manifest
that sets `cross.package.bin` is unaffected. See the entry under Cross.

**A flatpak with no `runtime_version` now builds against freedesktop `25.08`,
not `23.08`.** A manifest that sets `cross.package.flatpak` and omits the key
needs `org.freedesktop.Platform//25.08` and `org.freedesktop.Sdk//25.08`
installed on the build machine, and the device needs the `25.08` Platform to
run the result. With `vendor_libs`, the set of libraries copied into the
bundle is worked out against the new runtime, so it can change. To stay on the
old branch, set `runtime_version: '23.08'`; a manifest that already names a
version is unaffected.

**A relative `cross.sdk_path` or `cross.sdk_env_setup` changes your sysroot
key.** `_sysrootParts` hashes these values as stored, so a relative one used to
be hashed as the raw string and is now hashed as the resolved absolute path.
The build that moves is the one that works today: a flat manifest with
`sdk_path: sdk`, invoked from the project root, where the provider's
`existsSync` probe already resolved against the right directory. The *path* it
resolves to is unchanged; the *key* is not. Expect a one-time cold sysroot,
overlay and build directory, `emb.lock` drift (`--update-lock` to re-pin), and
one re-download for a `sdk_url` install, whose prefix is
`yocto-sdk-<sysrootKey>`. Absolute values are unaffected.

A consequence worth knowing: a relative value makes `sysroot_key` and
`build_key` depend on where the repo is checked out, since the resolved path
contains the clone directory. `augmentIdentity` already works this way
deliberately, but `buildKey` otherwise keeps checkout location out on purpose —
so a project sharing `emb.lock` between a developer and CI at different paths
will see drift on yocto-sdk targets where a relative value previously hashed
the same everywhere. Use an absolute path, or accept the per-clone key.

**`extends: 'source#<target>'` now means the checkout of `cross.source`.** It
used to mean a directory called `source` beside the manifest. Write
`./source#<target>` for the directory.

**`emb fetch` fetches what an offline build needs, so it downloads more and
can fail in more places.** With a manifest it now:

- takes the workspace from the manifest's `workspace:` ahead of
  `$FLUTTER_WORKSPACE` and the working directory, as `emb cross` does, so a
  fetch run elsewhere lands in the manifest's workspace. `--workspace` still
  wins;
- clones a declared `cross.source` and `cross.app`, which needs git and
  network access to both. `--app` replaces the declared app, as before;
- installs the Flutter SDK `flutter_version:` pins when the workspace has
  none, and runs `flutter precache`. This is a large download. An SDK already
  in the workspace is left alone;
- with an app, runs `flutter pub get` with the workspace's Flutter SDK ahead
  of the one on `PATH` (with neither it warns and carries on), and fetches the
  engine SDK for each `--mode`, `release` by default;
- resolves the closure with the app's `.emb/` layer merged, so sysroot
  packages and cargo modules only the app declares are fetched and `emb.lock`
  can gain what the build would have added on its first run.

Each step fails the fetch if it fails. `emb cross --fetch-only` now does all
of it too.

**`emb cross --build --offline` no longer downloads the engine SDK.** It
did, silently, when the SDK was not in the store. It now stops and names the
mode. `emb fetch` fetches the engine for `release` unless told otherwise, so a
build in another mode needs `emb fetch --mode <mode>` first.

**`emb cross` no longer fails on a target it was not asked to build.** A
target whose `extends:` does not resolve is reported when it is selected, and
`--list-targets` lists it as not resolved, with the reason, and exits 0.
Before, one such target failed every `emb cross` run on the manifest,
`--target local` included. A script that used `emb cross --list-targets` or
`--dry-run` to validate every target of a manifest has to select each target
to get the error. `emb fetch` and `emb doctor --target` do the same, and
`emb matrix` warns and skips such a target.

**`emb matrix` reads `.emb/` projects.** A directory holding a `.emb/`
project now renders a cell per target where it rendered none, with `manifest`
set to the board file and `args` to `<project> --target <name>`. Naming the
`.emb/` directory itself no longer renders a `base` cell, or board cells
without the base merged. A directory of flat manifests renders the same cells
as before. A CI job that fans out over `emb matrix` gains the project's cells.

**Modules build during `--prepare`, and `build.app_path` is deprecated.**
`emb cross --prepare` and `--build` without `--app` now build `cross.modules`,
so a module that fails to build fails them; a module whose path uses
`${app_root}` is skipped with a message when there is no app. Pass `--app`
instead of setting `build.app_path`.

**A profile or release bundle no longer carries the JIT snapshots.**
`isolate_snapshot_data`, `vm_snapshot_data`, `.last_build_id` and
`linux/<arch>/<mode>/CMakeCache.txt` are dropped from the bundle, and so from
the tarball, the flatpak and a deploy. Nothing an AOT engine runs needs them.

**Init.**

- feat(init): `emb init flatpak <dir> --app-id <id>` writes a flatpak
  packaging repo: a self-contained cross manifest (`cross.source`, `cross.app`,
  `workspace:`, `flutter_version:` and the flatpak block), a README,
  `.gitignore`, `metainfo.xml`, a placeholder `icon.png` and, unless
  `--ci none`, a one-job GitHub workflow. The embedder and app are pinned to
  the commit HEAD resolves to when the repo is generated, with the branch in a
  comment beside it. `--runtime-version` defaults to the newest freedesktop
  runtime flathub offers, else `25.08`. The manifest is resolved before
  anything is written. The repo builds natively (`--target local`).
  `--target <name>` adds a board target that extends the embedder's own
  target of that name (`extends: 'source#<name>'`), which is what an embedder
  with its own cross requirements needs; the name is not checked until the
  first build clones the embedder. For ivi-homescreen the target turns
  plugins off and the README's build command names `--backend wayland-egl`
  (`--backend` to change it). The workflow builds `--target local` only.
  A non-empty directory is refused without `--force`, and with it only files
  that still open with the `Generated by` line are replaced, or removed when a
  regeneration no longer writes them. Every path is checked before the first
  is written. Flag values and the app's pubspec `name` and `version` are held
  to their shape before use, `git ls-remote` and `flatpak remote-ls` are
  bounded and cannot prompt, and the generated workflow runs with a read-only
  token. The license is left
  as `TODO`, and the icon and description are placeholders that exist because
  `appstreamcli` fails a desktop application without them. The release in
  `metainfo.xml` is dated the day the repo is generated, since flatpak drops a
  release with no date. See
  [`emb init`](README.md#emb-init) and `examples/cross/init-flatpak/`.

**Security.**

- fix(repo): a manifest's `uri`, `branch`, `rev` and `dest_name` reached git
  and the filesystem unchecked. A `uri` beginning with `-` was read by
  `git clone` as an option, and with `dest_name` set to a `file://` URL of any
  local repository, `--upload-pack=<command>` ran the command. An absolute or
  `../` `dest_name` named a directory outside the workspace, which was deleted
  as a stale checkout before the clone. Both needed only a manifest the build
  resolved: the project's own, one reached through `extends:`, a board library
  entry or a `repos.json`. Such values are now refused before git runs or
  anything is deleted, a transport-helper `uri` (`ext::`) is refused, and git is
  given `--` so a value is an argument whatever it looks like.
  `git checkout <rev> --` also stops a `rev` that is a file name from
  restoring the file and reporting success.

**Cross.**

- feat(cross): `extends: 'source#<target>'` extends a target in the project
  the target's own `cross.source` clones (#309). A manifest that clones its
  embedder could not build it for a board: the embedder's project layer is
  inside the clone, `extends:` was resolved before anything was cloned, and
  the only way to name the layer was a path into the workspace that did not
  exist yet. `emb cross` now sets aside a target that does not resolve,
  clones the selected one's `cross.source`, and resolves again against the
  checkout. The path form (`workspace/app/<name>#<target>`) resolves the same
  way on a fresh checkout, though it breaks under `-w`. `--dry-run`, `--json`,
  `--clean` and `--list-targets` still fetch nothing and use a checkout that
  is already there. See Upgrading.

- fix(cross): with `cross.package.bin` unset, a shared library could be taken
  for the embedder, packaged and launched (#304). The search took the first
  file with the ELF magic and an execute bit, which a `.so` has too, in
  whatever order the filesystem listed the build tree: the same manifest
  picked `homescreen` on one filesystem and its shared library on another. It
  now takes
  programs only (`ET_EXEC`, or `ET_DYN` with an interpreter or the linker's PIE
  mark, and never a `*.so` name), and does not guess: more than one executable
  is an error that lists them and asks for `cross.package.bin`. **A project
  that builds several executables and relied on the pick must now set
  `cross.package.bin`.** A manifest that sets it is unaffected.

- feat(cross): `sdk_path` and `sdk_env_setup` may be written relative to the
  manifest that declares them, on the same rule `augment[].patches`,
  augment `path:` and `modules[].path` already follow. Absolute values are
  untouched, so an SDK installed at a machine path (the
  `/opt/fsl-imx-wayland/6.6` case in `examples/cross/README.md`) behaves
  exactly as before, and `sdk_url` is left alone because it is a URL.
  Previously only an absolute path resolved: the yocto-sdk provider tests the
  value with `Directory(path).existsSync()`, which resolves against the
  process's working directory, and a build does not run emb from the
  manifest's directory. The failure was also silent -- `_resolveEnvSetup`
  falls through to "no environment-setup-* found", which points at the SDK
  rather than at the path. So a board whose environment-setup script is
  committed beside its manifest had to name a path that exists on one
  machine; `sdk_path: sa8155p` in a `.emb/sa8155p.emb.yaml` now means
  `<project>/.emb/sa8155p` wherever the repo is cloned. Both values are
  hashed into `sysrootKey`, so this resolution happens before keys are
  computed, as it does for the other paths. A relative value declared in a
  board library resolves against that board's file, not the manifest that
  `extends:` it. An unexpanded `${…}` is refused at load, since nothing
  expands these two; an empty value is read as absent rather than as the
  manifest directory.

- feat(cross): modules are now built during `--prepare` (staged into
  `<buildRoot>/modules/`) and during `--build` without `--app` (standalone
  module build). Modules whose path references `${app_root}` are skipped with
  an informational message when `--app` is absent. `build.app_path` is
  deprecated; pass `--app` on the command line instead.

- fix(cross): a failed copy of the app bundle into the runnable directory
  ended `emb cross --build` with an unhandled exception. The copy ran outside
  the block that reports bundle errors, so a full disk or an exceeded quota
  printed a stack trace. It now fails with one line naming both paths and the
  reason, as does a failure to copy the embedder in or to clear the previous
  runnable directory.

- refactor(cross): `CrossTarget.withResolvedPatches` is now
  `withResolvedPaths`. It has resolved augment `path:` and `modules[].path`
  as well as patches for some time, and its own doc comment said so. Nothing
  under `lib/src/` is exported from `lib/emb_cli.dart`, so no public API
  changes.

**Fetch and offline builds.**

- feat(fetch): `emb fetch` clones a declared `cross.app` and prefetches its
  pub packages. It cloned `cross.source` and left the app out, so `emb cross
  --build --offline` after a fetch stopped at the app clone unless the app had
  been built online once. `pubspec_path` is honored, and the clone is the
  `${app_root}` that module paths resolve against. `emb cross --fetch-only`
  clones it as well, and so resolves the closure with the app's own `.emb/`
  layer merged, as the build does. The prefetch uses the workspace's Flutter
  SDK ahead of `PATH`. See Upgrading.

- fix(fetch): `emb fetch` left out two things `emb cross --build --offline`
  cannot get for itself. It resolved the target without the app's `.emb/`
  layer, so a `-dev` package or cargo module only the app declares was not
  in the closure; `emb cross` and `emb fetch` now resolve the target through
  the same code. And it did not install the SDK pinned by `flutter_version:`,
  so a cold workspace stopped the offline build at once; it now installs it
  and runs `flutter precache`. See Upgrading.

- fix(fetch): `emb fetch` and `emb doctor --target` stopped on any manifest
  with an `extends: 'source#<target>'` target, since only `emb cross` cloned
  `cross.source`. `emb fetch` now clones it, before the resolve when the
  target needs it, and for every target that declares one: `emb cross
  --offline` reuses the checkout and cannot make it, so a fetch that left it
  out did not make an offline build possible. `emb cross --fetch-only` does
  the same. `emb doctor --target` fetches nothing and resolves against a
  checkout that is there. Both take the workspace the way `emb cross` does,
  and `emb fetch` accepts `-w`, which its documentation already listed. See
  Upgrading.

- fix(cross): `emb cross --fetch-only` is documented as the same step as
  `emb fetch` and had fallen behind it: it installed no Flutter SDK, resolved
  no pub packages and fetched no engine, so an offline build prepared with it
  stopped at the first of those. The pub prefetch and the engine fetch move
  out of `emb fetch` into functions both commands call. See Upgrading.

- fix(cross): `emb cross --build --offline` and `--offline-strict` downloaded
  the engine SDK from GitHub when it was not cached (193 MB for
  release/x86_64). The engine is emb's own download, so the network namespace
  that confines build subprocesses does not cover it, and the engine's
  content store was never told the build was offline. It is now, for the
  bundle and for the AOT step's gen_snapshot lookup, and the build stops with
  the mode and what to run. `emb fetch` did not fetch the engine either, so
  the download was what made a fetched build work: with an app it now fetches
  the engine for each `--mode` (default `release`). See Upgrading.

**Matrix.**

- fix(matrix): `emb matrix` did not read `.emb/` projects. It globbed a
  directory's top-level `*.emb.yaml` files and read each alone, so a project
  directory rendered no cells, and its `.emb/` directory rendered
  `base.emb.yaml` as a target and every board file without the base merged
  under it. It now resolves each path as `emb cross` does, so its cells are
  the targets `emb cross --list-targets` shows; a board file that names no
  `supported_host_types` takes the base's. The matrix of a directory of flat
  manifests is unchanged (this repository's 30 cells are identical). The
  README gains an `emb matrix` reference section, and CI's matrix now
  includes `examples/cross/project`.

- fix(matrix): `emb matrix` skipped every `extends: 'source#<target>'`
  target, with the checkout of `cross.source` on disk or not, so a repo from
  `emb init flatpak --target <board>` rendered a matrix with no board in it.
  It now resolves such a target against a checkout in the workspace, which
  it finds the way `emb cross` does (new `-w`, then the manifest's
  `workspace:`, `$FLUTTER_WORKSPACE`, cwd). `--fetch` (new, off by default)
  clones a `cross.source` that is missing; without it the matrix still
  downloads nothing and the skip warning says how to get the cell.

**Bundle.**

- fix(bundle): a profile or release bundle shipped files no AOT engine reads.
  Its assets come from a debug-mode `flutter build bundle`, and the whole
  directory was copied with only `kernel_blob.bin` removed. That left the JIT
  `isolate_snapshot_data` (11.6 MB for the example app) and
  `vm_snapshot_data`, Flutter's `.last_build_id`, and the
  `linux/<arch>/<mode>/CMakeCache.txt` emb writes for build hooks, which names
  compiler paths on the build host. All are dropped from the assembled bundle,
  so from the tarball, flatpak and deploy too; a debug bundle keeps the
  snapshots it runs from. Applies to `emb cross`, `emb bundle` and
  `emb build`.

**Flatpak.**

- fix(cross): the default flatpak `runtime_version` was `23.08`, which flatpak
  reports end-of-life (#311). A manifest that omitted the key built against a
  runtime the user is warned about on install and that can leave flathub. The
  default is now `25.08`, held in one constant that `emb init flatpak` also
  falls back to, and a test fails if CI's flatpak job installs a different
  branch. See Upgrading.

- fix(cross): `--flatpak` no longer depends on where the project is checked
  out. flatpak-builder ran in `<build>/dist/<app_id>.flatpak-ctx`, and
  AppStream's compose step cannot write an icon to a path of 256 characters or
  more: it fails with `icon-write-error`, which names neither the path nor the
  limit. For an aarch64 build with a 24-character app id that path ran 216
  characters below the manifest's directory, which leaves 39 for the
  directory: a GitHub checkout (`/home/runner/work/<repo>/<repo>`) passes
  that with a repo name of 11 characters. The
  context now lives in `<cache>/tmp/fp-<hash>`, and a cache directory deep
  enough to hit the limit is refused up front with the path and the limit.

- fix(flatpak): the generated launcher takes its bundle flag from
  `cross.run.command` instead of writing `-b` a second time. `--run` became
  configurable in 0.4.0, but the flatpak packager kept its own literal, so an
  embedder spelling the flag differently worked under `--run` and was still
  handed `-b` inside the sandbox — one of the two gaps #224 named. A manifest
  with no `run.command` is unaffected: the default is `-b`. `flatpak.args`
  placing `{bundle}` still wins, being the more specific statement. The bundle
  path is made absolute, because every other consumer of the template cds into
  the bundle first (so the default spells it `.`) while the launcher execs from
  wherever `flatpak run` leaves it. A `run.command` that does not start with
  `${embedder}` cannot be reused this way and is refused with the alternative
  named.

- fix(flatpak): `cross.run.command` tokens reaching the launcher are validated.
  `_validate` walked `env` and `args` only, and `_shellWord` double-quotes on
  the assumption something already refused what a double-quoted word cannot
  hold — so routing `run.command` through it would have let a `$(…)` token from
  a manifest, or from a board library YAML, run at launch inside the sandbox.
  Tokens now get the same treatment as `args`, plus a refusal for an unexpanded
  `${…}` that the shell would otherwise expand.

- fix(flatpak): a launcher with no bundle flag and no args no longer has a
  double space in its exec line.

- fix(flatpak): staged libraries are checked for symbol versions, not only
  architecture. `FlatpakLibVendor._resolve` gated on `verifyElfForTriple`, which
  compares `e_machine` and word size — a host library built against a newer
  glibc passes it, stages cleanly, and then dies at startup inside the sandbox
  with `version 'GLIBC_2.38' not found`. With `--target local` the search root
  falls back to `/`, so that is the ordinary case rather than a contrived one.
  The same class of failure `vendor_libs` exists to prevent, one layer down —
  the third gap #224 named.

  Each staged library's `readelf -V` requirements are compared against the
  definitions in the runtime's own copy of the library they are aimed at.
  Membership, not a numeric comparison: the loader resolves a version by name,
  which is also what makes `GLIBC_ABI_DT_RELR` and friends fall out correctly.
  Requirements aimed at a library the runtime does not ship are skipped — either
  it was vendored alongside and carries its own definitions, or nothing provides
  it and `unresolved` already reports it.

  Warned, not failed, and deliberately quiet when it cannot tell: a runtime
  library that `readelf` could not read, or that defines no versions at all, is
  treated as unknown rather than as defining none, so an unversioned library
  does not turn every requirement into a warning. The arch check stays a hard
  skip, because a wrong-arch library is never usable.

**Container re-entry.**

- fix(exec): Forward host credentials (SSH agent, `~/.netrc`, `GH_TOKEN`) into
  Docker/Podman containers so authenticated artifact fetches work on container
  re-entry. On macOS/Windows with Docker Desktop, the SSH agent socket is
  forwarded via Docker Desktop's VM-side socket.

- fix(exec): Use Docker Desktop's `/run/host-services/ssh-auth.sock` only when
  running Docker; Podman on macOS falls back to direct socket bind-mount.

- feat(exec): Set `EMB_FORWARD_TOKEN=0` to suppress forwarding `GH_TOKEN` /
  `GITHUB_TOKEN` via Docker `-e` flags (visible in `ps aux` on shared
  workstations). Prefer `~/.netrc` when possible.

- feat(exec): the container gets a TTY and stdin when emb has them (#297,
  fixes #293). The container was run with neither `-i` nor `-t`, so inside it
  stdout was a pipe and stdin was closed: the inner emb, flutter, ninja and git
  ran without color or progress, and anything that prompted read EOF. `-i -t`
  are now passed together, and only when stdin, stdout and stderr are all
  terminals and emb is the foreground job. Redirected, piped, in the
  background or in CI, neither is passed and the run is as before.

- fix(exec): interrupting emb stops the container (#299, fixes #298). Ctrl-C
  on a containerized run with no TTY killed the host emb and left the
  container building: the signal reached the inner emb as PID 1, and the
  kernel drops a signal PID 1 has no handler for. The inner emb now exits 130
  on SIGINT and 143 on SIGTERM when it is PID 1. The host emb passes both on
  to the container client and waits for it, so `kill <emb pid>` and a CI
  cancel reach the container too; a second signal kills the client and stops
  waiting. A client that died of a signal is reported as 128 + n. An image
  whose emb predates this still ignores the first signal, so a container
  image that carries its own emb has to be rebuilt to get it.

- fix(aot): a relative `--gen-snapshot` or `--glibc-sysroot` named nothing
  inside the container (#300). The path was forwarded as typed while its
  mount was made at the absolute path, and the inner emb runs in the image's
  working directory. Both are made absolute before forwarding and mounting.
  The native path is unchanged.

**Tests and CI.**

- ci(cross): the `app bundle` job boots the bundle it built. Its stand-in
  embedder checks that the bundle's files exist, so a bundle whose engine
  cannot load its AOT image passed. A headless embedder
  (`examples/cross/app-bundle/boot/boot.c`) now links the engine the bundle
  ships, loads `lib/libapp.so` into it on the software renderer and fails
  unless the app presents a frame.

- ci(cross): an `app bundle (--app, native)` job builds an embedder and an
  app with `--app` on every PR (#302, refs #272). No cross job passed `--app`,
  so every cell stopped at the embedder and the runnable bundle path never
  ran: engine fetch, AOT, bundle assembly, module build and staging, the
  bundle audit, the tarball. `examples/cross/app-bundle/` is the smallest
  thing that goes through all of it: a stand-in embedder that checks the
  bundle is complete and loads the app's native module, and a Flutter app
  with that module. Built with `--target local`, from an empty workspace.

- ci(init): an `init flatpak (generated repo, cold build)` job generates a
  repo with `emb init flatpak` and builds it from an empty workspace with the
  commands its README gives (#310). The unit tests only showed that the
  output parses. The job installs the bundle, checks it holds the launcher,
  the embedder, `libapp.so`, the engine, the metainfo, the desktop file and
  the icon, and runs it. The embedder and app are the ones under
  `examples/cross/app-bundle/`, served from git repositories made in the job;
  ivi-homescreen, the default embedder, is not built there.

- test(aot): `emb aot` had two tests and now has 22, over the container path
  and the native path (#300, fixes #287).

- test: `emb engine` had no tests and now has 31, and the `EMB_CACHE_DIR`
  forwarding into the container is asserted where removing it used to leave
  the suite green (#301, fixes #286 and #288).

**Docs.**

- docs: the Flutter version named in examples rolls 3.44.2 -> 3.47.7. Docs,
  the `Dockerfile.runtime` build-arg example and the test fixtures only; no
  version is pinned in code, so `--flutter-version` and `globals.json`'s
  `flutter_version` still decide what gets checked out.

- docs: `extends:` is documented unqualified-first. The multi-source section
  presented `<source>/<target>` as how `extends:` resolves, without saying that
  an unqualified name resolves across every source and that a source name is a
  local choice in `boards.yaml` — so a manifest written from the docs only
  resolved for someone who picked the same name. The same paragraph claimed
  names never collide; board files do not, board names do, which is what the
  ambiguity error is for. #273.

- docs: the cross examples no longer carry a `build:` block. `emb cross` and
  `emb matrix` never read it — `build.app_path` is parsed by `BuildConfig` and
  consumed only by `emb build` — so eight example manifests declared a field
  with no effect on the command they demonstrate. #272.

# 0.4.1

Released from `main`, which holds 0.4.0 plus this one fix and nothing else
functional. Cut from the tree CI builds rather than cherry-picked onto the
`v0.4.0` tag — that mechanism is what shipped 0.3.7 broken, and there is nothing
to isolate here.

Upgrading from 0.4.0 needs nothing beyond `emb boards sync`, which now works. If
you applied the workaround from #261 — a second source named something else — you
can drop it: `emb boards remove <name>` and let the repaired default serve again.
Upgrading from 0.3.x: see the Upgrading section under 0.4.0 below, which still
applies.

**Boards.**

- fix(boards): the default source pointed one directory too high, so
  `emb boards sync` found nothing. 0.4.0 moved this repo's boards to
  `boards/emb-public/` but left `defaultSource` taking the source class's
  `path: 'boards'` default, which now holds only that subdirectory and no
  `*.emb.yaml`. Every pub.dev install hit it, and `emb boards sync` is what the
  0.4.0 upgrade notes say to run — so `extends:` resolved nothing and no build
  worked. Reported in #261 with the diagnosis already done.

  The path is now a named constant, `defaultSourcePath`, pinned by a test to the
  directory that actually holds `*.emb.yaml` in the checkout: move the boards
  again and that test fails instead of a user's first sync. The existing sync
  test could not catch this — its fake GitHub served whatever path the default
  asked for, so it stayed green while production broke. It derives the path from
  the constant now.

  A config written before the fix is repaired on load. `toMap` always writes
  `path`, so anyone who ran `emb boards add` has the stale value in their
  `boards.yaml`; correcting only the constant would leave them broken with no
  hint that a file was the reason. The repair is silent (this load runs on every
  `emb cross`, and emb wrote the bad value itself) and `boards sync` persists it,
  so the file converges on the command people are already told to run. Only the
  shipped default's full identity is touched — name, repo and the old path — so a
  source you aimed at `boards` yourself is left alone.

- fix(boards): a sync that finds no board files names the path and repo it
  listed. "No board files found for emb-public at v0.4.0" sent people to check
  the ref, which was fine.

# 0.4.0

Released from `main`, which is what CI validates: the full matrix builds example
apps for every example manifest across two host distributions on every commit. The
0.3.7 patch was cherry-picked onto the `v0.3.6` tag instead, and shipped broken —
it took the bundle audit's new parameter without the caller that fills it (#255).
Releasing the tree that gets tested is the correction.

## Upgrading

Three changes need something from you. Nothing else does.

**Cache keys move, so the first build after upgrading is cold.** Two separate
corrections: `augmentOverlayKey` and `buildKey` now hash resolved (absolute)
paths rather than raw manifest-relative values — augment `path:` and
`modules[*].path` both — and `augmentIdentity` now folds in `host` and
`host_pass`. A project with a `path:` augment, a `cross.modules` entry, or a
`host: true` augment sees a one-time cold sysroot, overlay and build directory,
and existing `emb.lock` entries report drift (`--update-lock` to re-pin). The old
keys were wrong, not merely different: they depended on the working directory, an
unexpanded `${app_root}` made two apps share one key and so one build directory,
and two augments differing only in `host` hashed the same — which let one's
host-tool stamp answer for the other, serving a native binary to a target build.

**The board library is laid out per source.** Boards install into
`<boards>/<source>/*.emb.yaml` rather than a flat directory, sources are declared
in `~/.config/emb/boards.yaml`, and the repo's own boards moved to
`boards/emb-public/`. Run `emb boards sync` after upgrading; `emb boards list`
reports what is loaded and which rung it came from. `extends:` still accepts an
unqualified target name — it resolves when exactly one source provides it — so
existing manifests keep working, but a target name two sources both provide is now
a hard error naming the qualified alternatives (`<source>/<target>`).

**`--tar` and `--deploy` now carry `cross.package.files`.** They were silently
dropped before. If you worked around that by hand — staging a config file into the
bundle yourself, or copying it to the board separately — that payload now arrives
twice. See the entry under Cross.

**Security.** A sweep over the packaging and deploy paths, prompted by reviewing
the board-registry and manifest-variable work. Every one of these took a value a
manifest or a board file supplies and let it reach a shell, a path, or a package
field unchecked:

- fix(rpm): a maintainer script was inlined into the generated spec, and rpmbuild
  macro-expands a spec — `%(command)` in a postinst ran on the **build host** at
  package time, and a line starting with `%` closed the scriptlet and injected
  spec directives. Scripts are referenced with `%post -f` and every `%` escaped;
  `-f` alone is not enough, which is what testing against real rpmbuild showed.
  (#233)
- fix(flatpak): `icon`, `files[].mode` and `files[].to` were interpolated bare
  into `build-commands`, which flatpak-builder runs through a shell; `to:` was
  also unnormalized, so `/../../../../etc/evil.conf` escaped the `/app` prefix.
  Values are shell-quoted, `mode` must be octal, and `to:` is confined. The same
  values were emitted as YAML plain scalars, so a `#` in a command name was
  silently truncated — they are quoted scalars now. (#234)
- fix(packaging): `package.name` named a directory that is deleted recursively,
  `files[].to` was checked with `isAbsolute` only (so `/../..` escaped the
  staging root, and `/../<pkg>.stage/DEBIAN/postinst` re-entered the control dir
  past the maintainer-script allowlist), `files[].mode` reached `chmod` as an
  argument (`--reference=/etc/shadow` stole another file's bits), and a newline
  in a deb/ipk control value added a field — `Essential: yes` made a package
  un-removable. All four validated. (#235)
- fix(cross): the tar-over-ssh push built its remote command with double quotes,
  so a deploy dir — or a `cross.backends` key concatenated into it — reached the
  board's shell. (#236)
- fix(cross): the generated Flutter custom device flattened `host`, `ssh_opts`
  and `adb_serial` into an `sh -c` script that runs on the developer's machine
  and is persisted in `custom_devices.config`, so it re-executed on every
  `flutter run -d`. (#232)
- fix(flutter): a malformed `custom_devices.json` was silently replaced, losing
  every device the user had registered; it is copied aside first and the path
  reported. The file was also left at the umask's mode (0644) while carrying
  `cross.run.env` values — now 0600. (#237)
- fix(packaging): one `chmod` per staged file, ~2000 spawns for a large asset
  tree; batched by mode, with `--` before the mode and the exit code checked.
  (#238, #240)

**Boards.**

- feat(cross): a configurable multi-source board registry. Board files can come
  from more than one repository — `emb boards add github org/repo --name priv`,
  over HTTPS with a PAT (`--token-env`) or SSH (`--transport ssh`) — each
  installed into its own subdirectory so two sources can both define a
  `rpi5-bookworm` without colliding. `extends:` resolves `<source>/<target>`, and
  an unqualified target still resolves when exactly one source provides it.
  Sources live in `~/.config/emb/boards.yaml`; `emb boards list --sources`,
  `emb boards sync --source <name>` and `emb boards remove <name>` manage them.
  Each source carries its own version stamp, so `emb doctor` reports skew per
  source rather than for the install as a whole. (#231)
- fix(boards): a `boards.yaml` emb could not parse was replaced by the defaults
  and written back, losing every source the user declared; a damaged install
  reported "up to date" forever because only the remote SHA was checked;
  `GIT_SSH_COMMAND` was replaced rather than extended, dropping a custom key in
  CI; the HTTP body had no size cap and no read timeout; and syncs shared one
  install dir with no lock. (#241)
- fix(doctor): board version stamps were enumerated from `boards.yaml`, which
  describes the installed layout only, so a library resolved from an
  `EMB_BOARDS_DIR` checkout reported its boards with no version and the skew
  check was blind. (#249)

**Cross.**

- feat(cross): `${embedder_root}`, `${app_root}` and `${runnable}` in manifest
  paths, so a manifest can name files across project boundaries and stay
  relocatable. Supported in `package.files`, `package.scripts`,
  `package.flatpak.icon`, `modules[*].path`, and augment `path:`/`patches:`;
  `${runnable}` needs `--app` and is packaging-only. See the variable table in
  the README for which fields bind which.
  `emb matrix` omits `sysroot_key`/`build_key` for a cell whose key-affecting
  paths still hold an unbound variable, and warns — a workflow that keys a cache
  on them must skip the step when they are empty, as `.github/workflows/cross.yaml`
  now does, or different boards collapse onto one cache entry.

- feat(cross): `cross.run.command` and `cross.run.env` — the command `--run`
  executes and the environment it runs under, instead of a hardcoded
  `./<embedder> -b .`. `${embedder}` and `${deploy_dir}` expand in it, the
  generated Flutter custom device uses the same command, and every token and env
  value is single-quoted for the remote shell. `run.env` keys must be shell
  identifiers (`[A-Za-z_][A-Za-z0-9_]*`): a key that is not checked becomes an
  assignment prefix in the remote shell, i.e. arbitrary command execution on the
  board from a board YAML. `run.env` is not for secrets — the values reach build logs,
  `custom_devices.config` and the deploy transport in cleartext.

- fix(cross): `--tar` and `--deploy` carry `cross.package.files`. The runnable
  bundle was the app bundle plus the embedder binary plus its linked libraries,
  and nothing read `spec.files` — so a config file or a systemd unit declared in
  the manifest reached a `.deb` but never a deployed board, silently, with no
  warning on either path. They stage under the bundle root: an absolute `to:`
  loses its leading separator, a relative one lands as-is. A source already
  inside the bundle is skipped, so the documented `${runnable}/lib/libfoo.so`
  pattern does not ship the library twice. `--flatpak` is unaffected; it applies
  `files:` itself at their `/app` paths, and now runs before the staging so it
  cannot ship them twice. Part of #216 — the two-package model in that issue is
  a separate change. **This changes what `--tar` produces and what `--deploy`
  pushes** for any manifest that declares `package.files`.
- feat(cross): `--deploy` and `--run` work without `--build`, shipping the bundle
  a previous build left behind — a redeploy after a failed transfer, a rerun to
  reproduce a crash, or pushing one build to a second board, none of which should
  cost another AOT pass. Nothing built is an error with guidance; a bundle older
  than the embedder source is deployed with a warning. (#214)
- feat(cross): an augment can see the augments before it — host-tool bins on
  `PATH`, the overlay ahead of the sysroot for pkg-config, and `${overlay}` /
  `${host_tools}` expanded in `defines:` so a build that imports an earlier
  augment through an export file can name the prefix. (#122)
- feat(cross): `host_pass:` on an augment entry builds its one source tree twice —
  a host pass with the build machine's toolchain, then the target pass — closing
  #122. Filament is the case: it generates its materials and shaders with `matc`,
  `resgen` and `cmgen`, compiled from its own source, so the build machine has to
  run build-machine binaries while the libraries they feed are target binaries.
  Both passes take the entry's `url`, `min`, `sha256`, `subdir` and patch series;
  `host_pass.defines` are merged over `defines:` so only the difference is
  written twice. The target pass's `defines:` can name its own host pass with
  `${host_prefix}` (the install prefix) and `${host_build}` (the build tree) —
  `${host_build}` is the one Filament needs, since the file that imports its
  generators is produced in the build tree and never installed. Using either
  without a `host_pass:` is refused at load rather than expanded to nothing.
  (#122)
- fix(cross): the two passes of one augment no longer share a build directory.
  The unpacked tree is keyed on `pkg` and `min`, so expressing a host and a
  target pass as two entries put both in `<src>/_build` — and the target pass
  wipes its build dir first, taking the host pass's tree, and anything the target
  pass had been told to import from it, with it. The host pass builds in
  `_build-host`.
- fix(cross): a `host: true` augment carrying `subdir:` configured the repository
  root and ignored it, while its cache key named the subtree. Both passes honor
  `subdir:` now.
- fix(cross): a host pass's `defines:` were passed to cmake/meson unexpanded, so
  a `${overlay}` or `${host_tools}` reached them verbatim. They expand on both
  passes, which matters now that a host pass inherits the entry's `defines:`.

# 0.3.7

A maintenance release cut from the `v0.3.6` tag, not from `main`: the two
bundle-audit fixes below and nothing else. Keeping the breaking changes out of a
patch was the intent; cherry-picking to do it was the mistake. The first fix
below landed here without the caller that feeds it, so this release did not fix
what it claimed to (#255) — the unit tests supply that argument themselves and
stayed green. 0.4.0 ships the tree CI builds instead.

- fix(cross): the bundle audit no longer rejects staged Dart code assets. An app
  whose dependency ships a native library as a code asset (sqlite3) had it copied
  into the bundle's `lib/` by emb and then refused by emb's own audit:
  `bundle lib/: unexpected file "libsqlite3.so"`. The audit takes the staged
  names as an input, read from where the stager copied them, so the two cannot
  drift. The arch check still applies. (#239)

- fix(cross): a bad bundle lib is reported once per file, with what to do about
  it, rather than once per audit pass.

# 0.3.6

Two cache-key corrections. Both are about a key that does not name everything
the thing it keys was built with, so two different trees can share one entry.

- fix(cross): `sysrootKey` folds in `cpu_flags` once an augment stages into the
  sysroot. Omitting them is right while a sysroot is only an extracted image --
  cpu-only variants of one board then share a single extraction -- and stops
  being right the moment an augment installs into it, because augments are
  compiled with the target's cpu flags. rpi5 (a76), rpi4 (a72) and
  rpi-zero-2w (a53) share one raspios image and so one key: prepare any of
  them and the other two reused a sysroot whose augments were tuned for
  whichever went first, with nothing detecting it. The wrong instructions
  surface as an illegal-instruction fault on the board, a long way from the
  build that chose them.
  `host: true` augments do not count -- they install to the workspace's host
  tools, never the sysroot -- and `sysrootBaseKey` is untouched, so the
  expensive half, the image download and extraction, stays shared as before.

- fix(cross): `augmentOverlayKey` folds in the sysroot and, where it matters,
  the host architecture. It hashed the target triple, cpu flags and augment
  set, which lets two overlays holding different binaries share a key: a
  bookworm and a trixie variant of one board match on all three and are kept
  apart today only by their differing augment lists. A `host: true` augment
  produces build-machine binaries, so an overlay built on x86_64 is unusable
  from an aarch64 host; that input is folded in only when the staged set
  contains such an augment, so a target-only overlay stays shared across hosts.
  Nothing consumes this key yet, so it is a correction ahead of use rather than
  a behavior change.

# 0.3.5

Tagged, never published: pub.dev goes 0.3.4 straight to 0.3.6, so there is no
0.3.5 to install. Everything below first reached pub.dev in 0.3.6, which
contains this tag in full — nothing here was lost. It will not be published
after the fact either, since it predates the two cache-key fixes in 0.3.6 and
would only offer a version whose `sysrootKey` still shares one sysroot across
cpu variants.

- fix(cross): `--publish` no longer skips a publish that leaves the shared cache
  empty. The fast path decided there was nothing to do from the image alone, but
  the image carries no toolchain — its dockerignore is `*` and it copies nothing
  — so the sysroot base and toolchain reach a consuming build through the shared
  cache instead. Skipping on the image alone left that cache empty permanently:
  the push that fills it runs only after a resolve populates the local store,
  and the resolve is exactly what the skip avoids, so the image kept looking up
  to date and the skip kept firing. The fast path now requires both halves, and
  a transport error counts as not-ready — an unreadable registry is a reason to
  do the work, not to assume it has been done.

- fix(cache): the shared-cache push works at all. Every push had failed since
  the transport was written, with `absolute file path detected` from `oras
  push`: the layer is a temp file this process has just written, so its path is
  absolute by construction. The failure was invisible because the push is
  best-effort — it warned, the build carried on, everything stayed green, and
  the cache the transport exists to fill stayed empty.

- fix(cache): the pushed layer can be pulled again. The path handed to `oras
  push` becomes the artifact's title, and `oras pull` uses it to decide where
  to write, so an absolute one asks every consumer to write outside its working
  directory and is refused. The first attempt at the previous fix disabled the
  push-side validation, which moved the failure downstream and made it worse:
  the artifacts reached the registry and could not be pulled at all. The layer
  is now pushed under its bare filename, with `oras` run from its own directory,
  so the title is relative and the artifact pulls anywhere — no flag on either
  side.

Together these are one bug in three parts: the shared cache had never been
written to. Measured on ivi-homescreen, every consuming build re-resolved its
toolchain from scratch — 91.8s on rpi4, 108.8s on rpi5, 97.3s on rpi-zero-2w,
per job, roughly forty minutes of runner time per run.

# 0.3.4

- fix(cross): `--publish` no longer skips a publish that would move a mutable
  tag. The skip-on-exists fast path probed only the content-addressed tag and
  returned before applying the others, so whatever `--tag <name>` pointed at
  when it was last really pushed, it kept pointing at — the content tag still
  existed, so the skip kept firing, so the push that would move the name never
  ran. Anything consuming the image by that name got an older one indefinitely.
  The skip now compares digests and fires only when every requested tag already
  resolves to the content tag; a digest that cannot be read counts as a reason
  to republish rather than as a match. The first publish after a tag has
  drifted does a full resolve — that is the run that repairs it.

# 0.3.3

- chore: require `packagekit_dart` 0.5.0 and `winget_dart` 0.4.0, which migrate
  their native build hooks to the `hooks` 2.x native-assets API (and drop the
  unused `native_toolchain_c`). No behavior change for emb — both
  host-provisioner backends build the same native bridge and still degrade
  cleanly when their toolchain is absent. emb already required Dart 3.10, which
  hooks 2.x needs.

# 0.3.2

- feat: build the Flutter engine for riscv64 and armv7hf, in both glibc and musl.
  The single source-build recipe now produces a green, C-ABI-clean engine for all
  seven arch/libc combinations in scope — x86_64, arm64, riscv64, and armv7hf,
  each in glibc and musl — every one validated with a from-scratch build.
  armv7hf selects hard float (its gnueabihf sysroot is hard-float, but gn defaults
  arm to softfp); riscv64 applies the gn-riscv and swiftshader-llvm-16 patches (its
  Reactor JIT needs llvm-16); and musl targets add a compiler-rt builtins fallback
  and turn off the glibc-only mallinfo/execinfo assumptions in swiftshader's
  vendored LLVM.
- fix: correct the 0.3.1 note that an x86_64-musl target is unsupported. When the
  build uses a custom target toolchain, the engine's gn already builds host tools
  with the glibc host toolchain, so an x86_64-musl target builds like any other —
  it only needs the same complete musl sysroot (libc++, libunwind, gcc) the other
  musl targets do.

# 0.3.1

- feat: build the Flutter engine for musl targets. The source build now handles
  a musl libc target — routing the in-tree libc++ to its native musl path,
  fixing the flatbuffers and swiftshader glibc assumptions, dropping the glibc
  execinfo backtrace, and applying its patch series with plain `patch` so it
  reaches nested engine DEPS repos. Validated with a from-scratch arm64-musl
  build whose `libflutter_engine.so` loads and runs a Dart app headless in an
  Alpine arm64 container, within 2.3% of the published glibc engine for the same
  commit. musl targets must be embedded architectures (arm64/riscv/armv7): an
  x86_64-musl target collides with the x86_64 host toolchain.
- fix: the engine ABI gate no longer false-fails a clean musl engine. Rule 6
  treated libc's `__cxa_atexit` / `__cxa_finalize` / `__cxa_thread_atexit_impl`
  as a libstdc++/libc++abi dependency, but those are the C runtime's
  static-destructor registration, provided by libc itself. The earlier glibc fix
  filtered version-tagged symbols, but musl carries no symbol version, so a clean
  musl engine tripped the rule. A genuine undefined `__cxa_throw` still fires.

# 0.3.0

- feat: build the Flutter engine from source when no prebuilt is published. When
  `emb engine` finds no published engine SDK for a `(commit, arch, mode)`, it can
  now build one on demand as an opt-in augment, producing a drop-in artifact that
  `aot`/`bundle` consume unchanged. A fail-closed ABI gate (readelf/nm) verifies
  the built `libflutter_engine.so` is a self-contained, C-ABI-clean drop-in
  before it is staged. The single `tool/engine/build-engine.sh` recipe — a
  fetch/build split mirroring Yocto's `do_fetch`/`do_compile`, with
  `--offline`/`--offline-strict` enforcement — is shared by emb,
  meta-flutter/flutter-engine CI, and a Yocto recipe, so the orchestration is not
  triplicated.
- feat: route Linux/x86_64 `aot`/`build`/`bundle` into a glibc container on a
  host that cannot run them natively (non-Linux or non-x86_64), re-entering emb
  with `--exec-native` behind an `EMB_IN_CONTAINER` guard so the inner run does
  not recurse.
- feat: `emb doctor --offline-probe --engine-commit <sha>` certifies that a
  fetched engine source closure can build with the network denied — the local
  analog of a Yocto `do_compile` sandbox — with the verdict carried in the
  `--json` envelope for CI.
- feat: add an Alpine `apk` host-dependency backend and a musl `-dev` sysroot
  provider. Alpine uses apk and OpenRC, not PackageKit/systemd, so host
  provisioning drives `apk` directly — no D-Bus, no systemd, no native bridge —
  and the musl cross sysroot is built from apk packages, the musl analog of the
  Debian dpkg path.
- feat: require `packagekit_dart` 0.4.3, whose build hook now skips the native
  bridge cleanly when cmake/ninja/libsystemd are absent. Without it, installing
  emb aborted in that hook on Alpine, minimal images, and any non-systemd host —
  even though emb never uses the PackageKit backend there — which is what the
  engine builder/runtime container images rely on.

# 0.2.0

- fix: the update notice is no longer printed under `--json`. It is written to
  stdout, so it landed after the envelope and made the output unparseable for
  exactly the callers who asked for machine-readable output.
- fix: only a *newer* published version is offered as an update. The check
  compared for inequality, so any unreleased build — every developer on main,
  and every release branch before its publish — was told to "update" to the
  older published version.
- feat: `emb doctor` reports the board library — resolved source rung, install
  path, board count, and any version skew, in both the text and `--json`
  output. A reachable emb with no board library is the same false green the
  authorization probe exists for: nothing looks wrong until a manifest uses
  `extends:`.
- fix: commands that take no positional arguments now reject stray ones
  instead of silently discarding them. `emb sync boards` ran the repository
  sync and reported "No source repositories found to sync", with no hint that
  `boards` had been dropped; it now names the stray argument and suggests
  `emb boards sync`.
- fix: `extends:` now works on an installed `emb`. `dart install` produces a
  standalone binary that carries no package data files, so `boards/` never
  reached it and every board name failed with `Known boards: none`. The board
  library is installed to `<data-home>/emb/boards` and resolved from there.
- fix: an empty board registry no longer reports `unknown board "<name>"`,
  which read as a typo and sent people to audit a correct manifest. It now says
  the library was not found and lists every path tried.
- feat: `emb boards list` (what is loaded, from which rung, with any version
  skew) and `emb boards sync` (install the library for a pub.dev install, which
  has no checkout to copy from).
- feat: add `--[no-]interactive` to `deps`, `setup`, and `cross`, plus the
  `EMB_NON_INTERACTIVE` environment variable, and honor `NONINTERACTIVE=1`
  (Homebrew's convention) as a secondary. `DEBIAN_FRONTEND` is deliberately
  not consulted: it suppresses the debconf package-configuration prompts rather
  than authorization, and images set it globally for that unrelated reason. Interactive is the unconditional
  default; nothing about the environment changes it, and `CI`-style variables
  are deliberately not consulted. Requires `packagekit_dart` 0.4.0, which sends
  the polkit `interactive` hint — without it no `emb deps` could install a
  package on a stock Fedora/openSUSE desktop unless the caller was root or
  covered by a permissive polkit rule.
- feat: decouple `--yes` from interactivity. `--yes` skips emb's own
  confirmation prompt only; `--no-interactive` implies `--yes` because nobody
  is there to answer, but the converse does not hold.
- feat: `brew` sets `NONINTERACTIVE=1` when non-interactive. WinGet accepts the
  flag for interface parity but has no equivalent to apply it to.
- feat: classify install failures. `ProvisionResult.kind` carries a typed
  `ProvisionFailure` (`notAuthorized`, `unresolved`, `daemonUnavailable`,
  `other`) derived from the backend's error codes, so the command layer no
  longer string-matches error text that varies by backend.
- feat: on an authorization failure, print remediation instead of a raw
  exception. The advice branches on the interactivity mode, because the daemon
  reports the same error whether it could not prompt or prompted and was
  refused.
- feat: `emb doctor` reports whether you are authorized to install host
  packages. Its other checks only exercise read-only operations, which need no
  authorization, so a reachable backend was previously reported green even when
  `emb deps` could not install anything. The probe never prompts.
- fix: defer the install spinner until the backend reports progress. An
  authorization prompt can appear first, and an animating spinner drew over it
  and made the password prompt unreadable.
- docs: document authorization, including why polkit cannot prompt under WSL
  and the narrowly scoped polkit rule that works there, plus what CI needs.
- fix: the documented polkit rule now matches both `wheel` (Fedora/RHEL/Arch)
  and `sudo` (Debian/Ubuntu). A `wheel`-only rule silently does nothing on
  Debian, which is hard to diagnose because the rule looks installed.
- test: CI job exercising authorization against a real PackageKit daemon —
  refusal with remediation before the rule is installed, unattended success
  after, and `EMB_NON_INTERACTIVE` equivalence.

# 0.1.1

- fix: locate the PackageKit native bridge (`libpackagekit_nc.so`) when emb is
  installed from pub.dev via `dart install emb_cli`. The code asset ships in the
  `dart install` app-bundle's `lib/` next to the executable; the resolver now
  finds it there (relative to `Platform.resolvedExecutable`). Previously the
  Linux backend reported "packagekit is not available" unless `PK_NC_LIB` or
  `LD_LIBRARY_PATH` was set by hand.

# 0.1.0

Port of `meta-flutter/workspace-automation` to a Dart CLI.

- feat: `emb doctor` — host detection + package-backend availability.
- feat: `emb deps` — coalesce host deps across manifests, filter, install in one
  PackageKit transaction (with `WhatProvides` resolution).
- feat: `emb sync` — concurrent git clone/update into `app/`.
- feat: `emb flutter` — install the Flutter SDK (auto-resolves the engine commit).
- feat: `emb engine` — fetch prebuilt engine artifacts from
  `meta-flutter/flutter-engine` releases (auto fetch-else-build).
- feat: `emb aot` — `create_aot.py` port producing `libapp.so` (profile/release).
- feat: `emb bundle` — assemble an ivi-homescreen bundle (debug JIT / AOT), with
  implicit engine fetch and cross-compile (`x86_64 → arm64/riscv64`).
- feat: `emb build` — manifest-driven build (`build:` block) over an arch × mode
  matrix.
- feat: `emb cross` — resolve a manifest `cross:` block into a toolchain +
  sysroot profile: cross-compile the native embedder for arm64/riscv64 with
  rootless sysroot extraction and Debian `.deb` handling.
- feat: `emb fetch` — fetch a cross target's toolchain + sysroot closure into
  the store: the online acquisition step for an offline build.
- feat: `emb matrix` — render a CI build matrix from manifest `cross:` blocks.
- feat: `emb cache` — inspect and reclaim the shared artifact cache.
- feat: `emb update` — self-update the CLI.
- feat: `emb setup` — one-shot provision; emits `setup_env.sh`.
- feat: `emb env` — write `setup_env.sh`.
- feat: install with `dart install` (Dart 3.10+), or with zero preinstalled
  toolchain via `bootstrap.sh`/`bootstrap.ps1`, which fetch a pinned Dart SDK
  and put `emb` on `PATH` in one step.
- feat: carry native code assets through cross-compiled bundles — stage them
  onto the loader path, build the Linux asset bundle, and accept
  `native_assets.json` for the kernel compile.
- feat: depend on the published `packagekit_dart` `^0.3.2` (hosted, not a path
  dependency).
- feat: auto-resolve the PackageKit native bridge (`libpackagekit_nc.so`) — from
  the package's own build or, for hosted installs, the `package:hooks` build-hook
  output under `.dart_tool/` — so the Linux backend works without `PK_NC_LIB`.
- docs: full per-command reference (every option, default, and value set) in the
  README; add `example/`.

# 0.0.1

- feat: initial commit 🎉
