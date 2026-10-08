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

Nothing yet. New entries go here, not under the heading below — the pubspec reads
`0.5.0-dev`, and work recorded under a published version is work no one can tell
was shipped. That is how the `0.3.6` section ended up mixing a released tag with
three blocks of later work, which 0.4.0 had to unpick.

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
