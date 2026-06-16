import 'dart:io';

/// An injectable process runner so providers and the overlay builder can be
/// unit-tested without spawning real subprocesses.
///
/// Defaults to [defaultProcessRunner] (a thin wrapper over [Process.run]).
/// Tests pass a fake that returns canned [ProcessResult]s and records the
/// argv it was called with. `EngineArtifacts` already takes an `HttpClient`
/// for the same reason; this is the process-side equivalent.
typedef ProcessRunner =
    Future<ProcessResult> Function(
      String executable,
      List<String> arguments, {
      String? workingDirectory,
      Map<String, String>? environment,
      bool includeParentEnvironment,
      bool runInShell,
    });

/// The production [ProcessRunner]: forwards to [Process.run].
Future<ProcessResult> defaultProcessRunner(
  String executable,
  List<String> arguments, {
  String? workingDirectory,
  Map<String, String>? environment,
  bool includeParentEnvironment = true,
  bool runInShell = false,
}) => Process.run(
  executable,
  arguments,
  workingDirectory: workingDirectory,
  environment: environment,
  includeParentEnvironment: includeParentEnvironment,
  runInShell: runInShell,
);
