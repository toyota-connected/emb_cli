// Boots a bundle on the Flutter engine it ships, headless, and waits for the
// app to present a frame. The stand-in embedder next door checks that the
// bundle's files exist; this checks that they work together: the engine loads
// the AOT image from lib/libapp.so, starts the root isolate and renders.
//
// Software renderer, no window system, no input: it needs nothing but the
// bundle and the engine's embedder header.
//
// Build with the include directory of the engine SDK and the bundle's lib/:
//
//   cc -o boot boot.c -I<engine-sdk>/include -L<bundle>/lib -lflutter_engine
//
// and run it as `./boot <bundle>` with <bundle>/lib on the loader's path.
#include <flutter_embedder.h>
#include <stdatomic.h>
#include <stdio.h>
#include <unistd.h>

static atomic_int g_frames;
static atomic_int g_isolate;

static bool on_present(void *user, const void *pixels, size_t row_bytes,
                       size_t height) {
  (void)user;
  (void)pixels;
  if (atomic_fetch_add(&g_frames, 1) == 0)
    printf("frame:   %zu bytes/row x %zu rows\n", row_bytes, height);
  return true;
}

static void on_isolate(void *user) {
  (void)user;
  atomic_store(&g_isolate, 1);
}

static void on_log(const char *tag, const char *message, void *user) {
  (void)user;
  printf("dart:    [%s] %s\n", tag, message);
}

int main(int argc, char **argv) {
  // Unbuffered: the engine's threads outlive main, so the process leaves
  // through _exit and would take buffered output with it.
  setvbuf(stdout, NULL, _IONBF, 0);
  if (argc != 2) {
    fprintf(stderr, "usage: boot <bundle>\n");
    return 2;
  }
  char assets[4096], icu[4096], app[4096];
  snprintf(assets, sizeof assets, "%s/data/flutter_assets", argv[1]);
  snprintf(icu, sizeof icu, "%s/data/icudtl.dat", argv[1]);
  snprintf(app, sizeof app, "%s/lib/libapp.so", argv[1]);

  // A JIT engine would ignore libapp.so and want a kernel blob instead.
  if (!FlutterEngineRunsAOTCompiledDartCode()) {
    printf("FAIL: this engine is not an AOT runtime\n");
    return 1;
  }

  FlutterEngineAOTDataSource source = {0};
  source.type = kFlutterEngineAOTDataSourceTypeElfPath;
  source.elf_path = app;
  FlutterEngineAOTData aot = NULL;
  FlutterEngineResult r = FlutterEngineCreateAOTData(&source, &aot);
  if (r != kSuccess) {
    printf("FAIL: the engine cannot load %s (%d)\n", app, r);
    return 1;
  }

  FlutterRendererConfig renderer = {0};
  renderer.type = kSoftware;
  renderer.software.struct_size = sizeof(FlutterSoftwareRendererConfig);
  renderer.software.surface_present_callback = on_present;

  FlutterProjectArgs args = {0};
  args.struct_size = sizeof(FlutterProjectArgs);
  args.assets_path = assets;
  args.icu_data_path = icu;
  args.aot_data = aot;
  args.root_isolate_create_callback = on_isolate;
  args.log_message_callback = on_log;

  FlutterEngine engine = NULL;
  r = FlutterEngineRun(FLUTTER_ENGINE_VERSION, &renderer, &args, NULL, &engine);
  if (r != kSuccess) {
    printf("FAIL: the engine did not start (%d)\n", r);
    return 1;
  }
  printf("engine:  running\n");

  // Nothing is laid out, and so nothing presented, until the view has a size.
  FlutterWindowMetricsEvent metrics = {0};
  metrics.struct_size = sizeof metrics;
  metrics.width = 320;
  metrics.height = 240;
  metrics.pixel_ratio = 1.0;
  r = FlutterEngineSendWindowMetricsEvent(engine, &metrics);
  if (r != kSuccess) {
    printf("FAIL: the engine refused window metrics (%d)\n", r);
    _exit(1);
  }

  for (int i = 0; i < 300 && atomic_load(&g_frames) == 0; i++)
    usleep(100 * 1000);

  printf("isolate: %s\n", atomic_load(&g_isolate) ? "created" : "not created");
  if (atomic_load(&g_frames) == 0) {
    printf("FAIL: the app presented no frame in 30s\n");
    _exit(1);
  }
  printf("booted:  the app presented a frame\n");
  _exit(0);
}
