import 'package:emb_cli/src/commands/cross_command.dart';
import 'package:test/test.dart';

void main() {
  group('mergeBackendDefines', () {
    test('gives every backend a bundle-relative rpath by default', () {
      final defines = mergeBackendDefines(const {}, const {});
      expect(defines['CMAKE_BUILD_WITH_INSTALL_RPATH'], 'ON');
      // The executable sits at the bundle root, a library inside lib/; both
      // reach the staged libraries without an absolute build-host path.
      expect(defines['CMAKE_INSTALL_RPATH'], r'$ORIGIN/lib:$ORIGIN');
    });

    test('keeps a manifest rpath, so a board can still opt out', () {
      final defines = mergeBackendDefines(const {
        'CMAKE_INSTALL_RPATH': '/opt/vendor/lib',
      }, const {});
      expect(defines['CMAKE_INSTALL_RPATH'], '/opt/vendor/lib');
      // Only the overridden key is replaced.
      expect(defines['CMAKE_BUILD_WITH_INSTALL_RPATH'], 'ON');
    });

    test('a backend define outranks both the target and the default', () {
      final defines = mergeBackendDefines(
        const {'CMAKE_INSTALL_RPATH': '/from/target'},
        const {'CMAKE_INSTALL_RPATH': '/from/backend'},
      );
      expect(defines['CMAKE_INSTALL_RPATH'], '/from/backend');
    });

    test('carries the target and backend entries through untouched', () {
      final defines = mergeBackendDefines(
        const {'BUILD_BACKEND_DRM': 'ON'},
        const {'BUILD_BACKEND_WAYLAND': 'OFF'},
      );
      expect(defines['BUILD_BACKEND_DRM'], 'ON');
      expect(defines['BUILD_BACKEND_WAYLAND'], 'OFF');
    });
  });
}
