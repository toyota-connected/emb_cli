import 'dart:io';

import 'package:emb_cli/src/cross/arm_gnu_cross_provider.dart';
import 'package:emb_cli/src/cross/cross_provider.dart';
import 'package:emb_cli/src/cross/cross_target.dart';
import 'package:emb_cli/src/cross/yocto_recipe_cross_provider.dart';
import 'package:emb_cli/src/cross/yocto_sdk_cross_provider.dart';
import 'package:emb_cli/src/host/host_info.dart';
import 'package:emb_cli/src/workspace/workspace.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('emb_xfor_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  const host = HostInfo(
    os: HostOs.linux,
    machineArch: 'x86_64',
    archAliases: {'x86_64', 'x64', 'amd64'},
    hostType: 'fedora',
    versionId: '43',
  );

  CrossProvider forProvider(String token) => CrossProvider.forTarget(
    CrossTarget.fromMap({'provider': token}),
    workspace: Workspace(tmp),
    host: host,
  );

  test('forTarget dispatches by provider kind', () {
    expect(forProvider('arm-gnu'), isA<ArmGnuCrossProvider>());
    expect(forProvider('yocto-recipe'), isA<YoctoRecipeCrossProvider>());
    expect(forProvider('yocto-sdk'), isA<YoctoSdkCrossProvider>());
  });

  test('providers expose a name and preflight tools', () {
    expect(forProvider('arm-gnu').name, 'arm-gnu');
    expect(forProvider('arm-gnu').preflightTools, contains('rsync'));
    expect(forProvider('yocto-recipe').preflightTools, contains('pkg-config'));
    expect(forProvider('yocto-sdk').preflightTools, contains('bash'));
  });

  test('forTarget threads offline into the arm-gnu provider', () {
    final on = CrossProvider.forTarget(
      CrossTarget.fromMap({'provider': 'arm-gnu'}),
      workspace: Workspace(tmp),
      host: host,
      offline: true,
    );
    expect((on as ArmGnuCrossProvider).offline, isTrue);
    // Default stays online.
    expect((forProvider('arm-gnu') as ArmGnuCrossProvider).offline, isFalse);
  });
}
