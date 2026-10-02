const defaultRunTemplate = [r'./${embedder}', '-b', '.'];

List<String> applyRunVars(
  List<String> tokens,
  Map<String, String> vars, {
  Set<String>? unknowns,
}) => [
  for (final t in tokens)
    t.replaceAllMapped(RegExp(r'\$\{([^}]*)\}'), (m) {
      final name = m[1]!;
      if (!vars.containsKey(name)) {
        unknowns?.add(name);
        return m[0]!;
      }
      return vars[name]!;
    }),
];

String _shQuote(String s) => "'${s.replaceAll("'", r"'\''")}'";

String runCmdString(List<String> argv, {Map<String, String> env = const {}}) {
  final parts = [
    for (final e in env.entries) '${e.key}=${_shQuote(e.value)}',
    ...argv.map(_shQuote),
  ];
  return parts.join(' ');
}
