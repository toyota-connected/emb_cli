import 'dart:io';

import 'package:emb_cli/src/env/env_script.dart';
import 'package:emb_cli/src/host/host_info.dart';
import 'package:emb_cli/src/workspace/workspace.dart';
import 'package:test/test.dart';

const _host = HostInfo(
  os: HostOs.linux,
  machineArch: 'x86_64',
  archAliases: {'x86_64', 'x64', 'amd64'},
  hostType: 'fedora',
  versionId: '43',
);

void main() {
  test('emits the core workspace env', () {
    final s = generateSetupEnv(
      workspace: Workspace(Directory('/ws')),
      host: _host,
      engineVersion: 'deadbeef',
    );
    expect(s, contains('export FLUTTER_WORKSPACE="/ws"'));
    expect(s, contains(r'$FLUTTER_WORKSPACE/flutter/bin'));
    expect(s, contains('dart-sdk/bin'));
    expect(s, contains(r'export PUB_CACHE="$FLUTTER_WORKSPACE'));
    expect(s, contains('export HOST_ARCH_GOOGLE="x64"')); // flutterArch
    expect(s, contains('export FLUTTER_ENGINE_VERSION="deadbeef"'));
    expect(s, startsWith('#!/bin/sh'));
  });

  test('omits FLUTTER_ENGINE_VERSION when unknown', () {
    final s = generateSetupEnv(
      workspace: Workspace(Directory('/ws')),
      host: _host,
    );
    expect(s, isNot(contains('FLUTTER_ENGINE_VERSION')));
  });
}
