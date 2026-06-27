// Architecture derivation from a target triple, shared by the toolchain
// emitter and the ARM GNU sysroot wiring so neither hardcodes `aarch64`.

/// The CPU arch token of a triple: `aarch64-none-linux-gnu` → `aarch64`,
/// `arm-none-linux-gnueabihf` → `arm`, `riscv64-poky-linux` → `riscv64`.
String archOfTriple(String triple) => triple.split('-').first.toLowerCase();

/// The Meson `cpu_family` / CMake `CMAKE_SYSTEM_PROCESSOR` for a triple.
String cpuFamilyOfTriple(String triple) => switch (archOfTriple(triple)) {
  'arm' || 'armv7' || 'armv7l' || 'armhf' => 'arm',
  'aarch64' || 'arm64' => 'aarch64',
  'riscv64' => 'riscv64',
  'x86_64' || 'amd64' => 'x86_64',
  final a => a,
};

/// The Debian multiarch tuple for a triple's arch: `aarch64-linux-gnu`,
/// `arm-linux-gnueabihf`, `riscv64-linux-gnu`, `x86_64-linux-gnu`.
String debianMultiarch(String triple) => switch (archOfTriple(triple)) {
  'aarch64' || 'arm64' => 'aarch64-linux-gnu',
  'arm' || 'armv7' || 'armv7l' || 'armhf' => 'arm-linux-gnueabihf',
  'riscv64' => 'riscv64-linux-gnu',
  'x86_64' || 'amd64' => 'x86_64-linux-gnu',
  final a => '$a-linux-gnu',
};

/// The dpkg architecture name for a triple (`aarch64-*` → `arm64`,
/// `arm-*` → `armhf`), used to pick the right apt `Packages` index.
String debianArch(String triple) => switch (archOfTriple(triple)) {
  'aarch64' || 'arm64' => 'arm64',
  'arm' || 'armv7' || 'armv7l' || 'armhf' => 'armhf',
  'riscv64' => 'riscv64',
  'x86_64' || 'amd64' => 'amd64',
  final a => a,
};

/// The flatpak architecture name for a triple (`aarch64-*` → `aarch64`,
/// `arm-*` → `arm`), used for `flatpak-builder --arch` / `build-bundle --arch`
/// and to pick the matching `org.freedesktop.Platform` runtime.
String flatpakArch(String triple) => switch (archOfTriple(triple)) {
  'aarch64' || 'arm64' => 'aarch64',
  'arm' || 'armv7' || 'armv7l' || 'armhf' => 'arm',
  'riscv64' => 'riscv64',
  'x86_64' || 'amd64' => 'x86_64',
  final a => a,
};
