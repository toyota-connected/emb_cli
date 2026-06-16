/// emb — Flutter Embedder CLI.
///
/// Provisions a Flutter embedded-Linux workspace (host deps, repos, SDK,
/// engine) and builds ivi-homescreen bundles, including cross-compiled AOT for
/// arm64 / riscv64 from an x86_64 host.
///
/// ```sh
/// # activate
/// dart pub global activate --source=path .
///
/// # usage
/// emb --help
/// ```
library;
