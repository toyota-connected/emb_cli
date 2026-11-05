import 'dart:io';

import 'package:emb_cli/src/command_runner.dart';
import 'package:emb_cli/src/pkg/native_lib.dart';

Future<void> main(List<String> args) async {
  // Locate the PackageKit native library before any backend use (Linux).
  await configurePackageKitLibrary();
  await _flushThenExit(await EmbCliCommandRunner().run(args));
}

/// Flushes the stdout and stderr streams, then exits the program with the given
/// status code.
///
/// This returns a Future that will never complete, since the program will have
/// exited already. This is useful to prevent Future chains from proceeding
/// after you've decided to exit.
Future<void> _flushThenExit(int status) {
  return Future.wait<void>([
    stdout.close(),
    stderr.close(),
  ]).then<void>((_) => exit(status));
}
