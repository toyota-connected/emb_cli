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

/// The opkg/ipk architecture for a triple's arch. opkg arch names usually
/// track the CPU arch (or a Yocto MACHINE tuning such as `cortexa53`); this
/// returns the plain CPU-arch default, overridable per manifest via
/// `package.ipk.arch` for tuning-specific feeds.
String opkgArch(String triple) => switch (archOfTriple(triple)) {
  'aarch64' || 'arm64' => 'aarch64',
  'arm' || 'armv7' || 'armv7l' || 'armhf' => 'arm',
  'riscv64' => 'riscv64',
  'x86_64' || 'amd64' => 'x86_64',
  final a => a,
};

/// The rpm architecture for a triple (`aarch64-*` → `aarch64`, `arm-*` →
/// `armv7hl`), used for `rpmbuild --target` and the spec's `BuildArch`.
String rpmArch(String triple) => switch (archOfTriple(triple)) {
  'aarch64' || 'arm64' => 'aarch64',
  'arm' || 'armv7' || 'armv7l' || 'armhf' => 'armv7hl',
  'riscv64' => 'riscv64',
  'x86_64' || 'amd64' => 'x86_64',
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

/// The ELF `e_machine` value expected for a triple's arch (`aarch64` →
/// `EM_AARCH64` 0xB7, `arm` → `EM_ARM` 0x28, `riscv64` → `EM_RISCV` 0xF3,
/// `x86_64` → `EM_X86_64` 0x3E). Returns 0 for an arch with no known mapping,
/// which callers treat as "skip the machine check" rather than a mismatch.
int elfMachine(String triple) => switch (archOfTriple(triple)) {
  'aarch64' || 'arm64' => 0xB7,
  'arm' || 'armv7' || 'armv7l' || 'armhf' => 0x28,
  'riscv64' => 0xF3,
  'x86_64' || 'amd64' || 'x64' => 0x3E,
  final _ => 0,
};

/// The ELF class expected for a triple's arch: 1 = ELFCLASS32 (32-bit), 2 =
/// ELFCLASS64 (64-bit). Only `arm` is 32-bit among the arches emb targets.
int elfClass(String triple) => switch (archOfTriple(triple)) {
  'arm' || 'armv7' || 'armv7l' || 'armhf' => 1,
  final _ => 2,
};

/// Whether the triple's ABI mandates the ARM hard-float ELF flag
/// (`EF_ARM_ABI_FLOAT_HARD`, 0x400). True for the `*eabihf` arm triples
/// (`arm-…-gnueabihf`, `armhf-*`), whose objects must not be mixed with a
/// soft-float runtime. Only meaningful for the 32-bit `arm` family.
bool elfArmHardFloat(String triple) =>
    elfClass(triple) == 1 &&
    (triple.toLowerCase().contains('hf') || archOfTriple(triple) == 'armhf');

/// The Rust target triple for a GNU triple's arch (`aarch64-*` →
/// `aarch64-unknown-linux-gnu`, `arm-*`/`armhf` → `armv7-unknown-linux-gnueabihf`),
/// used for `cargo build --target` and the target-suffixed cargo env vars.
/// Derived from the GNU triple — boards carry no separate `rust_triple`.
String rustTriple(String triple) => switch (archOfTriple(triple)) {
  'aarch64' || 'arm64' => 'aarch64-unknown-linux-gnu',
  'arm' || 'armv7' || 'armv7l' || 'armhf' => 'armv7-unknown-linux-gnueabihf',
  'riscv64' => 'riscv64gc-unknown-linux-gnu',
  'x86_64' || 'amd64' => 'x86_64-unknown-linux-gnu',
  final a => '$a-unknown-linux-gnu',
};
