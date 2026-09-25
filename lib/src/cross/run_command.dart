const defaultRunTemplate = [r'./${embedder}', '-b', '.'];

List<String> applyRunVars(
  List<String> tokens,
  Map<String, String> vars, {
  Set<String>? unknowns,
}) => [
  for (final t in tokens)
    t.replaceAllMapped(RegExp(r'\$\{([a-zA-Z0-9_]+)\}'), (m) {
      final name = m[1]!;
      if (!vars.containsKey(name)) {
        unknowns?.add(name);
        return m[0]!;
      }
      return vars[name]!;
    }),
];

String runCmdString(List<String> argv) =>
    argv.map((t) => "'${t.replaceAll("'", r"'\''")}'").join(' ');
