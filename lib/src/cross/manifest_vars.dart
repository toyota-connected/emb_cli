/// Expand `${key}` tokens in [s] using [vars].
///
/// Only keys present in [vars] are substituted; unknown tokens are left
/// verbatim so an unresolved `${runnable}` in a context where no runnable
/// exists remains visible rather than silently becoming the empty string.
///
/// If expansion produces an absolute path, callers using `p.join(base, ...)`
/// get the absolute path unchanged — `p.join` drops the prefix when the
/// trailing argument is absolute.
String expandManifestVars(String s, Map<String, String> vars) =>
    s.replaceAllMapped(RegExp(r'\$\{(\w+)\}'), (m) {
      final key = m.group(1)!;
      return vars.containsKey(key) ? vars[key]! : m.group(0)!;
    });
