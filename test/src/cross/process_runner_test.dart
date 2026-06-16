import 'package:emb_cli/src/cross/process_runner.dart';
import 'package:test/test.dart';

void main() {
  test('defaultProcessRunner forwards to Process.run', () async {
    final ok = await defaultProcessRunner('sh', ['-c', 'exit 0']);
    expect(ok.exitCode, 0);

    final bad = await defaultProcessRunner('sh', ['-c', 'exit 3']);
    expect(bad.exitCode, 3);
  });

  test('defaultProcessRunner passes the environment through', () async {
    final r = await defaultProcessRunner(
      'sh',
      ['-c', r'printf %s "$EMB_T"'],
      environment: {'EMB_T': 'hi'},
    );
    expect(r.stdout, 'hi');
  });
}
