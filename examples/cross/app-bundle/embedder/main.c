// A stand-in embedder. It renders nothing: given `-b <bundle>` it checks that
// the bundle emb assembled is complete and that the app's native module loads,
// which is what a real embedder would need before it could start the engine.
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

static int need(const char *bundle, const char *rel) {
  char path[4096];
  snprintf(path, sizeof path, "%s/%s", bundle, rel);
  if (access(path, R_OK) != 0) {
    fprintf(stderr, "missing: %s\n", path);
    return 1;
  }
  printf("found:   %s\n", rel);
  return 0;
}

int main(int argc, char **argv) {
  const char *bundle = NULL;
  for (int i = 1; i + 1 < argc; i++) {
    if (strcmp(argv[i], "-b") == 0) bundle = argv[i + 1];
  }
  if (bundle == NULL) {
    fprintf(stderr, "usage: %s -b <bundle>\n", argv[0]);
    return 2;
  }

  int missing = 0;
  missing += need(bundle, "data/flutter_assets/AssetManifest.bin");
  missing += need(bundle, "data/icudtl.dat");
  missing += need(bundle, "lib/libflutter_engine.so");
  missing += need(bundle, "lib/libapp.so");
  missing += need(bundle, "lib/libhello.so");
  if (missing != 0) return 1;

  char path[4096];
  snprintf(path, sizeof path, "%s/lib/libhello.so", bundle);
  void *lib = dlopen(path, RTLD_NOW);
  if (lib == NULL) {
    fprintf(stderr, "dlopen: %s\n", dlerror());
    return 1;
  }
  const char *(*hello)(void) = (const char *(*)(void))dlsym(lib, "hello");
  if (hello == NULL) {
    fprintf(stderr, "dlsym: %s\n", dlerror());
    return 1;
  }
  printf("module:  %s\n", hello());
  return 0;
}
