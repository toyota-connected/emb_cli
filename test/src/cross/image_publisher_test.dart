import 'package:emb_cli/src/cross/image_publisher.dart';
import 'package:test/test.dart';

void main() {
  group('ImagePublishPlan', () {
    ImagePublishPlan plan({
      List<String> tags = const ['abc123'],
      bool push = true,
      String tool = 'docker',
    }) => ImagePublishPlan(
      tool: tool,
      contextDir: '/ctx',
      imagePrefix: 'ghcr.io/org/emb-cross-aarch64-none-linux-gnu',
      tags: tags,
      push: push,
    );

    test('refs join the prefix with each tag', () {
      final p = plan(tags: ['abc123', 'bookworm-latest']);
      expect(p.refs(), [
        'ghcr.io/org/emb-cross-aarch64-none-linux-gnu:abc123',
        'ghcr.io/org/emb-cross-aarch64-none-linux-gnu:bookworm-latest',
      ]);
      expect(p.primaryRef, endsWith(':abc123'));
    });

    test('existsProbe prefers skopeo (works on podman + docker)', () {
      final probe = plan().existsProbe(skopeoAvailable: true);
      expect(probe.exe, 'skopeo');
      expect(probe.args, [
        'inspect',
        'docker://ghcr.io/org/emb-cross-aarch64-none-linux-gnu:abc123',
      ]);
    });

    test(
      'existsProbe falls back to <tool> manifest inspect without skopeo',
      () {
        final probe = plan().existsProbe(skopeoAvailable: false);
        expect(probe.exe, 'docker');
        expect(probe.args, [
          'manifest',
          'inspect',
          'ghcr.io/org/emb-cross-aarch64-none-linux-gnu:abc123',
        ]);
      },
    );

    // The skip-on-exists fast path probes the primary (content-addressed) tag.
    // Any other tag is mutable, so existence says nothing about what it points
    // at -- a stale one exists, keeps the content probe matching, and keeps the
    // skip firing, so the name is never corrected and every consumer of it gets
    // an older image. Comparing digests is what closes that, and needs a probe
    // that reports one.
    test('digestProbe reports a digest for any ref, not just the primary', () {
      final p = plan(tags: ['abc123', 'bookworm']);
      final probe = p.digestProbe(p.refs()[1], skopeoAvailable: true);
      expect(probe.exe, 'skopeo');
      expect(probe.args, [
        'inspect',
        '--format',
        '{{.Digest}}',
        'docker://ghcr.io/org/emb-cross-aarch64-none-linux-gnu:bookworm',
      ]);
    });

    test('digestProbe falls back to the container tool without skopeo', () {
      final p = plan(tags: ['abc123', 'bookworm']);
      final probe = p.digestProbe(p.refs()[1], skopeoAvailable: false);
      expect(probe.exe, 'docker');
      expect(probe.args, [
        'manifest',
        'inspect',
        '--verbose',
        'ghcr.io/org/emb-cross-aarch64-none-linux-gnu:bookworm',
      ]);
    });

    test('build tags every ref and ends with the context dir', () {
      final cmd = plan(tags: ['abc123', 'latest']).build();
      expect(cmd.exe, 'docker');
      expect(cmd.args, [
        'build',
        '-t',
        'ghcr.io/org/emb-cross-aarch64-none-linux-gnu:abc123',
        '-t',
        'ghcr.io/org/emb-cross-aarch64-none-linux-gnu:latest',
        '/ctx',
      ]);
    });

    test('pushes one command per tag', () {
      final pushes = plan(tags: ['abc123', 'latest']).pushes();
      expect(pushes.map((c) => c.args), [
        ['push', 'ghcr.io/org/emb-cross-aarch64-none-linux-gnu:abc123'],
        ['push', 'ghcr.io/org/emb-cross-aarch64-none-linux-gnu:latest'],
      ]);
    });

    test('no-push yields no push commands', () {
      expect(plan(push: false).pushes(), isEmpty);
    });

    test('honors a custom container tool (podman)', () {
      final p = plan(tool: 'podman');
      expect(p.build().exe, 'podman');
      expect(p.existsProbe(skopeoAvailable: false).exe, 'podman');
      expect(p.pushes().single.exe, 'podman');
    });

    test('works against an Artifactory prefix unchanged', () {
      final p = ImagePublishPlan(
        tool: 'docker',
        contextDir: '/ctx',
        imagePrefix:
            'corp.jfrog.io/docker-local/emb-cross-aarch64-none-linux-gnu',
        tags: ['k'],
      );
      expect(
        p.primaryRef,
        'corp.jfrog.io/docker-local/emb-cross-aarch64-none-linux-gnu:k',
      );
    });
  });
}
