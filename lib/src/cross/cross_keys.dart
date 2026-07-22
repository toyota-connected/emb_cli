import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:emb_cli/src/cross/cross_target.dart';
import 'package:emb_cli/src/repo/patch_series.dart';

/// Stable short content hash (12 hex chars) of [parts].
String contentHash(List<String> parts) =>
    sha256.convert(utf8.encode(parts.join('\n'))).toString().substring(0, 12);

String _kv(Map<String, String> m) {
  final keys = m.keys.toList()..sort();
  return [for (final k in keys) '$k=${m[k]}'].join(',');
}

/// A module's build-identity-affecting fields, flattened for [buildKey].
String _module(ModuleSpec m) => [
  m.name,
  m.build.name,
  m.path,
  m.artifacts.join(','),
  m.features.join(','),
  _kv(m.defines),
].join(':');

/// The provider/toolchain + sysroot-source inputs, shared by [sysrootKey] and
/// [sysrootBaseKey]. Order is significant — it fixes both hashes.
List<String> _sysrootParts(CrossTarget t) => [
  'provider:${t.provider.token}',
  'triple:${t.targetTriple ?? ''}',
  'tc:${t.toolchainVersion ?? ''}',
  'tcurl:${t.toolchainUrl ?? ''}',
  'policy:${t.versionPolicy.name}',
  'recipe:${t.recipe}',
  'yoctoBuild:${t.yoctoBuild ?? ''}',
  'machine:${t.machineTuple ?? ''}',
  'sdkPath:${t.sdkPath ?? ''}',
  'sdkUrl:${t.sdkUrl ?? ''}',
  'sdkEnv:${t.sdkEnvSetup ?? ''}',
  if (t.sysroot case final s?) ...[
    'src:${s.source.name}',
    'img:${s.imageUrl ?? ''}',
    'dev:${s.deviceHost ?? ''}:${s.sshPort}',
    'part:${s.partition}',
    'pkgs:${(s.devPackages.toList()..sort()).join(",")}',
    'snap:${s.snapshot ?? ''}',
    'links:${_kv(s.symlinks)}',
  ],
];

/// Hash of the inputs that determine a target's **toolchain + sysroot**:
/// provider, toolchain version/policy, the sysroot source (image/device +
/// partition + dev packages) and the augment set. Deliberately excludes
/// `cpu_flags`/`backends`/`defines`, so cpu-only variants of one board (e.g.
/// rpi4 vs rpi5 on the same raspios image) share a single extraction.
String sysrootKey(CrossTarget t) => contentHash([
  ..._sysrootParts(t),
  // Only augments that will actually be staged count toward the key: a
  // `requires_define`-gated augment whose gate isn't satisfied (e.g. an
  // off-by-default crash handler) is not built, so it must not perturb the
  // sysroot identity or invalidate the shared store entry.
  for (final a in t.augment)
    if (CrossTarget.defineSatisfied(a.requiresDefine, t.defines))
      'aug:${augmentIdentity(a)}',
]);

/// An augment's build identity: the fields that change what gets produced,
/// including a digest of its patch series.
///
/// The patch digest is load-bearing. Nothing else here moves when a patch is
/// edited in place — `url` and `min` stay put — so without it a store entry
/// built from the previous series would be reused silently. [patchSeriesDigest]
/// tolerates unreadable paths, so an unresolvable patch still produces a
/// stable, distinct key rather than throwing during key computation.
///
/// Patch paths must already be resolved (see `resolvePatchPaths`); a relative
/// path here would hash whatever it resolves to from the current directory.
String augmentIdentity(AugmentLib a) => [
  a.pkg,
  a.minVersion,
  a.url,
  a.build.name,
  '${a.staticLink}',
  if (a.patches.isNotEmpty) 'patches:${patchSeriesDigest(a.patches)}',
].join(':');

/// Hash naming a cached **augment overlay** — the built artifacts of a
/// target's augment set, as distinct from the sysroot they layer onto.
///
/// Unlike [sysrootBaseKey] and the toolchain key, which are deliberately
/// augment-independent so one blob serves many variations, this is
/// augment-specific by construction: it exists to name the overlay itself.
/// It therefore folds in everything that changes the overlay's contents —
/// the target triple and cpu flags the libs are compiled for, plus each
/// staged augment's [augmentIdentity].
///
/// Gated augments are excluded on the same reasoning as [sysrootKey]: one that
/// is not built must not perturb the identity of an overlay that lacks it.
String augmentOverlayKey(CrossTarget t) => contentHash([
  'triple:${t.targetTriple ?? ''}',
  'cpu:${t.cpuFlags.join(" ")}',
  for (final a in t.augment)
    if (CrossTarget.defineSatisfied(a.requiresDefine, t.defines))
      'aug:${augmentIdentity(a)}',
]);

/// Hash of the **shared sysroot base**: [sysrootKey] without the augment set,
/// since augments build into a separate per-workspace overlay prefix rather
/// than the sysroot. Names the `sysroot-base` store entry, so one image
/// extraction is shared across every target that differs only in its augments.
String sysrootBaseKey(CrossTarget t) => contentHash(_sysrootParts(t));

/// The `toolchain` store key: `(vendor, version, host-arch, target-triple)`.
/// Independent of the sysroot, so every target/workspace on the same toolchain
/// shares one download + extraction. [tcHost] is the build-machine arch mapped
/// to the vendor's naming (`aarch64` or `x86_64`).
String armGnuToolchainKey({
  required String version,
  required String tcHost,
  required String triple,
}) => 'arm-gnu-toolchain-$version-$tcHost-$triple';

/// Hash of the **full build** configuration: everything in [sysrootKey] plus
/// cpu flags, generator, backends, defines and raw cmake args. Names the
/// per-board build dir (and the cpu-specific emitted toolchain file).
String buildKey(CrossTarget t) => contentHash([
  sysrootKey(t),
  'cpu:${t.cpuFlags.join(" ")}',
  'gen:${t.generator.name}',
  for (final e in t.backends.entries) 'be:${e.key}:${_kv(e.value)}',
  for (final m in t.modules) 'mod:${_module(m)}',
  'def:${_kv(t.defines)}',
  'cmake:${t.cmakeArgs.join(" ")}',
]);
