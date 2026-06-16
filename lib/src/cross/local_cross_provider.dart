import 'package:emb_cli/src/cross/cross_arch.dart';
import 'package:emb_cli/src/cross/cross_profile.dart';
import 'package:emb_cli/src/cross/cross_provider.dart';
import 'package:emb_cli/src/host/host_info.dart';

/// The implicit `local` (alias `host`) target: a **native** build on the dev
/// machine. No cross toolchain, no image/sysroot download — `resolve()` returns
/// a profile with the host compiler and no toolchain file, so the build stage
/// runs a plain CMake/Meson build against the host's system libraries.
///
/// Selected by `--target local` / `--target host`, and the default when a
/// manifest defines `cross.targets` but none is chosen.
class LocalCrossProvider implements CrossProvider {
  LocalCrossProvider(this.host);

  final HostInfo host;

  @override
  String get name => 'local';

  /// A pseudo-triple naming the native build dir (e.g. `x86_64-linux-gnu`).
  @override
  String get triple => '${host.machineArch}-linux-gnu';

  @override
  List<String> get preflightTools => const [];

  @override
  Future<CrossResolveResult> resolve() async {
    if (host.os != HostOs.linux) {
      return CrossResolveResult.unavailable(
        'local builds are Linux-only for now; host is ${host.os.name}',
      );
    }
    // No toolchain file and an empty sysroot → the build stage configures a
    // native CMake/Meson build with the host toolchain. `cc`/`cxx` are the
    // host defaults (and only cosmetic — CMake auto-detects without a
    // toolchain file; the deb packager derives the host `readelf` from `cc`).
    return CrossResolveResult.ok(
      CrossProfile(
        providerName: name,
        targetTriple: triple,
        cc: 'gcc',
        cxx: 'g++',
        ar: 'ar',
        strip: 'strip',
        targetSysroot: '',
      ),
    );
  }

  /// Debian architecture of the host (e.g. `amd64`), for a native `.deb`.
  String get debArch => debianArch(host.machineArch);
}
