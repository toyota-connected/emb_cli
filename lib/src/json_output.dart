import 'dart:convert';

/// Serialize a machine-readable command result as the stable top-level
/// envelope `{schema, command, ok, data}`, pretty-printed (indent 2).
///
/// Used by `--json` on `emb cross --dry-run` and `emb doctor` so CI and IDE
/// tooling get a consistent, versioned shape. Bump [schema] on a breaking
/// change to the `data` layout.
String jsonEnvelope(
  String command, {
  required bool ok,
  required Object? data,
  int schema = 1,
}) => const JsonEncoder.withIndent(
  '  ',
).convert({'schema': schema, 'command': command, 'ok': ok, 'data': data});
