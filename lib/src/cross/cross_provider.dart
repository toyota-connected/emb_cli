import 'package:emb_cli/src/cross/arm_gnu_cross_provider.dart';
import 'package:emb_cli/src/cross/cross_profile.dart';
import 'package:emb_cli/src/cross/cross_target.dart';
import 'package:emb_cli/src/cross/yocto_recipe_cross_provider.dart';
import 'package:emb_cli/src/cross/yocto_sdk_cross_provider.dart';
import 'package:emb_cli/src/host/host_info.dart';
import 'package:emb_cli/src/workspace/workspace.dart';

/// Resolves a target's toolchain + sysroot(s) into a single [CrossProfile],
/// regardless of provenance.
///
/// Concrete providers wrap exactly one provenance model and are selected at
/// runtime by [forTarget] — the same dispatch shape as
/// `HostProvisioner.forHost`. Everything downstream of [resolve] (toolchain-
/// file emit, configure/build, augmentation, deploy) consumes the returned
/// [CrossProfile] and never branches on which provider produced it.
abstract class CrossProvider {
  /// Provider token for diagnostics (`arm-gnu`, `yocto-recipe`, `yocto-sdk`).
  String get name;

  /// The effective target triple used to name this provider's working dirs
  /// (`cross-<triple>`, `cross-build-<triple>`, `overlay-<triple>`).
  /// Best-effort and resolve-free, so `emb cross --clean` needs no download.
  String get triple;

  /// Host tools that must be present for this provider to function.
  ///
  /// Provider-declared rather than a fixed preflight list: the ARM GNU path
  /// needs `qemu-aarch64-static` for its apt chroot; the Yocto providers need
  /// none. The caller diffs this against `PATH` before invoking [resolve].
  List<String> get preflightTools;

  /// Resolve the cross environment: fetch/extract/locate/source as needed and
  /// return a [CrossProfile].
  ///
  /// Resolution never mutates a shared sysroot — source-built augmentation
  /// libraries are installed into a workspace overlay by a separate step, so a
  /// read-only or shared Yocto SDK sysroot stays pristine.
  Future<CrossResolveResult> resolve();

  /// Content-addressed store selectors `(kind, key)` this provider can fetch
  /// from a shared OCI cache *before* resolving, so a build pulls them instead
  /// of re-downloading and re-extracting. Empty by default — only providers
  /// with a content-addressed image base (arm-gnu) override this.
  List<({String kind, String key})> cacheSelectors() => const [];

  /// Select the provider for [target] on [host], rooted at [workspace].
  static CrossProvider forTarget(
    CrossTarget target, {
    required Workspace workspace,
    required HostInfo host,
  }) => switch (target.provider) {
    CrossProviderKind.armGnu => ArmGnuCrossProvider(
      target,
      workspace: workspace,
      host: host,
    ),
    CrossProviderKind.yoctoRecipe => YoctoRecipeCrossProvider(
      target,
      workspace: workspace,
      host: host,
    ),
    CrossProviderKind.yoctoSdk => YoctoSdkCrossProvider(
      target,
      workspace: workspace,
      host: host,
    ),
  };
}
