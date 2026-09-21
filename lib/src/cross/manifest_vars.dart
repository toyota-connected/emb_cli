/// Expand `${key}` tokens in [s] using [vars].
///
/// Only keys present in [vars] are substituted; unknown tokens are left
/// verbatim so an unresolved `${runnable}` in a context where no runnable
/// exists remains visible rather than silently becoming the empty string.
String expandManifestVars(String s, Map<String, String> vars) =>
    vars.entries.fold(s, (acc, e) => acc.replaceAll('\${${e.key}}', e.value));
