import 'dart:io';

/// The `--parallel <n>` count to give a `cmake --build`.
///
/// Passing `--parallel` with no count defers to the generator's own default,
/// and for Makefiles that default is a bare `-j`: unbounded. Small projects get
/// away with it; a large one does not. Building the Firebase C++ SDK as an
/// augment (gRPC and protobuf are the worst of it) spawns compile jobs until
/// the machine is out of memory and the OOM killer takes `cc1plus` down
/// mid-build, which surfaces as an unexplained
/// `c++: fatal error: Killed signal terminated program cc1plus`. So state a
/// number.
///
/// The number is bounded by memory rather than by CPU count alone. The heaviest
/// C++ translation units in that dependency set peak near 2-3 GB resident, and
/// a host with many cores relative to its RAM will happily start more of them
/// than it can finish -- one job per ~4 GB keeps a full parallel build inside
/// the machine. Where `/proc/meminfo` is not available (macOS, Windows) there is
/// nothing to bound against, so the CPU count stands on its own.
///
/// `CMAKE_BUILD_PARALLEL_LEVEL` overrides the estimate outright: CMake honors
/// that variable itself, and a caller who has set it has said what they want.
int cmakeBuildJobs([Map<String, String>? environment]) {
  final env = environment ?? Platform.environment;
  final configured = int.tryParse(env['CMAKE_BUILD_PARALLEL_LEVEL'] ?? '');
  if (configured != null && configured > 0) return configured;

  final cpus = Platform.numberOfProcessors;
  final memGb = _totalMemoryGb();
  if (memGb == null) return cpus;
  final byMemory = memGb ~/ 4;
  if (byMemory < 1) return 1;
  return byMemory < cpus ? byMemory : cpus;
}

/// Total physical memory in GiB from `/proc/meminfo`, or null off Linux (or if
/// the file is unreadable or shaped unexpectedly).
int? _totalMemoryGb() {
  try {
    final meminfo = File('/proc/meminfo');
    if (!meminfo.existsSync()) return null;
    for (final line in meminfo.readAsLinesSync()) {
      if (!line.startsWith('MemTotal:')) continue;
      final kb = int.tryParse(
        RegExp(r'(\d+)').firstMatch(line)?.group(1) ?? '',
      );
      if (kb == null) return null;
      return kb ~/ (1024 * 1024);
    }
  } on IOException {
    return null;
  }
  return null;
}
