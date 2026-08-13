import 'package:emb_cli/src/host/host_info.dart';

/// Where a Linux-x86_64 engine operation must run.
///
/// The engine's clang, the CIPD tools, and `gen_snapshot` are Linux-x86_64
/// glibc binaries, so on a non-Linux / non-x86_64 host the work is routed into a
/// glibc Linux container.
sealed class ExecEnv {
  const ExecEnv();
}

/// Run directly on the host (a Linux x86_64 host, or already in the container).
class NativeExec extends ExecEnv {
  const NativeExec();
}

/// Re-enter emb inside a glibc Linux [image]
/// (`docker run <image> emb … --exec-native`).
class ContainerExec extends ExecEnv {
  const ContainerExec({required this.image, required this.reason});

  final String image;
  final String reason;
}

const Set<String> _x64Aliases = {'x86_64', 'amd64', 'x64'};

/// Resolve where a Linux-target engine operation runs on [host].
///
/// Native only when the host can itself run the Linux-x86_64 toolchain — a
/// Linux x86_64 host — or when [inContainer] (the recursion guard) or
/// [forceNative]
/// (`--native`) is set. Everything else routes through the container [image].
ExecEnv resolveExecEnv(
  HostInfo host, {
  required String image,
  bool inContainer = false,
  bool forceNative = false,
}) {
  if (inContainer || forceNative) return const NativeExec();
  final isLinux = host.os == HostOs.linux;
  final isX64 = _x64Aliases.contains(host.machineArch.toLowerCase());
  if (isLinux && isX64) return const NativeExec();
  final reason = !isLinux
      ? 'host OS is ${host.os.name}, not linux'
      : 'host arch is ${host.machineArch}, not x86_64';
  return ContainerExec(image: image, reason: reason);
}
