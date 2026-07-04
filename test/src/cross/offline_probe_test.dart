import 'package:emb_cli/src/cross/offline_probe.dart';
import 'package:test/test.dart';

void main() {
  group('OfflineProbe', () {
    test('ok only when every check passed', () {
      const pass = OfflineProbe(
        target: 'pi5',
        checks: [
          ProbeCheck('a', ok: true),
          ProbeCheck('b', ok: true, detail: 'available'),
        ],
      );
      expect(pass.ok, isTrue);

      const fail = OfflineProbe(
        target: 'pi5',
        checks: [
          ProbeCheck('a', ok: true),
          ProbeCheck('b', ok: false, detail: 'run emb fetch'),
        ],
      );
      expect(fail.ok, isFalse);
    });

    test('toData carries target, verdict, and per-check detail', () {
      const probe = OfflineProbe(
        target: 'pi5',
        checks: [ProbeCheck('cargo foo vendored', ok: false, detail: 'x')],
      );
      final data = probe.toData();
      expect(data['target'], 'pi5');
      expect(data['ok'], false);
      final checks = data['checks']! as List<Object?>;
      expect(checks.single, {
        'name': 'cargo foo vendored',
        'ok': false,
        'detail': 'x',
      });
    });

    test('a check without detail omits the field', () {
      expect(const ProbeCheck('x', ok: true).toData(), {
        'name': 'x',
        'ok': true,
      });
    });
  });
}
