import 'package:emb_cli/src/host/preflight.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:test/test.dart';

void main() {
  group('Preflight.missingTools', () {
    test('returns the subset the probe reports absent, in order', () async {
      final pf = Preflight(
        Logger(),
        probe: (t) async => t != 'xz' && t != 'rsync',
      );
      expect(await pf.missingTools(['tar', 'xz', 'rsync']), ['xz', 'rsync']);
    });

    test('is empty when every tool is present', () async {
      final pf = Preflight(Logger(), probe: (_) async => true);
      expect(await pf.missingTools(['tar', 'xz']), isEmpty);
    });

    test('an empty tool list never probes', () async {
      var probed = false;
      final pf = Preflight(
        Logger(),
        probe: (_) async {
          probed = true;
          return true;
        },
      );
      expect(await pf.missingTools(const []), isEmpty);
      expect(probed, isFalse);
    });
  });
}
