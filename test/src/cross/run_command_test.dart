import 'package:emb_cli/src/cross/run_command.dart';
import 'package:test/test.dart';

void main() {
  group('applyRunVars', () {
    test('substitutes known variables', () {
      expect(
        applyRunVars([r'./${embedder}', '-b', '.'], {'embedder': 'homescreen'}),
        ['./homescreen', '-b', '.'],
      );
    });

    test('substitutes multiple variables in one token', () {
      expect(
        applyRunVars(
          [r'${deploy_dir}/${embedder}'],
          {'embedder': 'app', 'deploy_dir': '/opt'},
        ),
        ['/opt/app'],
      );
    });

    test('collects unknown variables', () {
      final unknowns = <String>{};
      final result = applyRunVars(
        [r'./${embeder}', '-b', '.'],
        {'embedder': 'homescreen'},
        unknowns: unknowns,
      );
      expect(unknowns, {'embeder'});
      expect(result, ['./', '-b', '.']);
    });

    test('unknown variable expands to empty string', () {
      expect(applyRunVars([r'${nope}'], {}), ['']);
    });

    test('leaves tokens without variables unchanged', () {
      expect(applyRunVars(['--config', '/etc/app.conf'], {}), [
        '--config',
        '/etc/app.conf',
      ]);
    });

    test('empty token list returns empty list', () {
      expect(applyRunVars([], {'embedder': 'x'}), <String>[]);
    });
  });

  group('runCmdString', () {
    test('single-quotes each token', () {
      expect(runCmdString(['./app', '-b', '.']), "'./app' '-b' '.'");
    });

    test('escapes embedded single quotes', () {
      expect(runCmdString(["it's"]), r"'it'\''s'");
    });

    test('handles empty argv element', () {
      expect(runCmdString(['']), "''");
    });

    test('handles spaces in tokens', () {
      expect(runCmdString(['./my app', '--flag']), "'./my app' '--flag'");
    });
  });

  group('defaultRunTemplate', () {
    test('expands to the expected default', () {
      expect(applyRunVars(defaultRunTemplate, {'embedder': 'homescreen'}), [
        './homescreen',
        '-b',
        '.',
      ]);
    });
  });
}
