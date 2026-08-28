import 'dart:io';

import 'package:emb_cli/src/cross/build_jobs.dart';
import 'package:test/test.dart';

void main() {
  group('cmakeBuildJobs', () {
    test('honors CMAKE_BUILD_PARALLEL_LEVEL over the estimate', () {
      expect(cmakeBuildJobs({'CMAKE_BUILD_PARALLEL_LEVEL': '3'}), 3);
    });

    test('ignores a non-positive or unparsable override', () {
      final estimate = cmakeBuildJobs(const {});
      for (final bad in ['0', '-4', 'many', '']) {
        expect(
          cmakeBuildJobs({'CMAKE_BUILD_PARALLEL_LEVEL': bad}),
          estimate,
          reason: 'override "$bad" should not be taken',
        );
      }
    });

    test('never returns less than one job', () {
      expect(cmakeBuildJobs(const {}), greaterThanOrEqualTo(1));
    });

    test('never exceeds the CPU count', () {
      // The point of the bound is to stay *under* the unbounded `-j` that a
      // bare `cmake --build --parallel` hands the Make generator.
      expect(
        cmakeBuildJobs(const {}),
        lessThanOrEqualTo(Platform.numberOfProcessors),
      );
    });

    test('bounds by memory where /proc/meminfo is readable', () {
      // On Linux the estimate allows roughly one job per 4 GiB, so a host with
      // many cores relative to its RAM does not start more compile jobs than it
      // can finish. Elsewhere there is nothing to bound against.
      if (!File('/proc/meminfo').existsSync()) return;
      final memTotalKb = int.parse(
        RegExp(r'MemTotal:\s+(\d+)')
            .firstMatch(File('/proc/meminfo').readAsStringSync())!
            .group(1)!,
      );
      final byMemory = (memTotalKb ~/ (1024 * 1024)) ~/ 4;
      if (byMemory < 1) return;
      expect(
        cmakeBuildJobs(const {}),
        byMemory < Platform.numberOfProcessors
            ? byMemory
            : Platform.numberOfProcessors,
      );
    });
  });
}
