import 'package:emb_cli/src/cross/cross_profile.dart';
import 'package:emb_cli/src/cross/cross_target.dart';
import 'package:test/test.dart';

void main() {
  group('ModuleSpec.fromMap', () {
    test('parses build token, path, artifacts, defines, and features', () {
      final m = ModuleSpec.fromMap(const {
        'name': 'codec',
        'path': 'native/codec',
        'build': 'meson',
        'artifacts': ['libcodec.so', 'libcodec_helper.so'],
        'defines': {'CODEC_FAST': 'ON'},
        'features': ['neon'],
        'profile': 'release',
      });
      expect(m.name, 'codec');
      expect(m.path, 'native/codec');
      expect(m.build, ModuleBuild.meson);
      expect(m.artifacts, ['libcodec.so', 'libcodec_helper.so']);
      expect(m.defines, {'CODEC_FAST': 'ON'});
      expect(m.features, ['neon']);
      expect(m.profile, 'release');
    });

    test('build defaults to cmake', () {
      final m = ModuleSpec.fromMap(const {
        'name': 'a',
        'path': 'a',
        'artifacts': ['liba.so'],
      });
      expect(m.build, ModuleBuild.cmake);
    });

    test('cargo/rust token maps to ModuleBuild.cargo with no generator', () {
      expect(ModuleBuild.fromToken('cargo'), ModuleBuild.cargo);
      expect(ModuleBuild.fromToken('rust'), ModuleBuild.cargo);
      expect(ModuleBuild.cargo.generator, isNull);
      expect(ModuleBuild.cmake.generator, CrossGenerator.cmake);
      expect(ModuleBuild.meson.generator, CrossGenerator.meson);
    });

    test('an unknown build token throws', () {
      expect(
        () => ModuleSpec.fromMap(const {
          'name': 'a',
          'path': 'a',
          'build': 'bazel',
          'artifacts': ['liba.so'],
        }),
        throwsArgumentError,
      );
    });

    test('a missing name or path throws', () {
      expect(
        () => ModuleSpec.fromMap(const {
          'path': 'a',
          'artifacts': ['liba.so'],
        }),
        throwsArgumentError,
      );
      expect(
        () => ModuleSpec.fromMap(const {
          'name': 'a',
          'artifacts': ['liba.so'],
        }),
        throwsArgumentError,
      );
    });

    test('an empty or missing artifacts list is an error', () {
      expect(
        () => ModuleSpec.fromMap(const {'name': 'a', 'path': 'a'}),
        throwsArgumentError,
      );
      expect(
        () => ModuleSpec.fromMap(const {
          'name': 'a',
          'path': 'a',
          'artifacts': <String>[],
        }),
        throwsArgumentError,
      );
    });
  });

  group('CrossTarget modules', () {
    test('parses a modules: list', () {
      final t = CrossTarget.fromMap(const {
        'provider': 'arm-gnu',
        'triple': 'aarch64-none-linux-gnu',
        'modules': [
          {
            'name': 'hello',
            'path': 'native/hello',
            'artifacts': ['libhello.so'],
          },
        ],
      });
      expect(t.modules, hasLength(1));
      expect(t.modules.single.name, 'hello');
    });

    test('defaults to an empty modules list', () {
      final t = CrossTarget.fromMap(const {
        'provider': 'arm-gnu',
        'triple': 'aarch64-none-linux-gnu',
      });
      expect(t.modules, isEmpty);
    });
  });
}
