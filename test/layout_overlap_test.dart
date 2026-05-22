import 'package:flutter_test/flutter_test.dart';
import 'package:kanshi_gui/models/monitor_tile_data.dart';
import 'package:kanshi_gui/services/layout_math.dart';

MonitorTileData _mon({
  required String id,
  double x = 0,
  double y = 0,
  double w = 1920,
  double h = 1080,
  double scale = 1.0,
  bool enabled = true,
  String? mirrorOf,
}) =>
    MonitorTileData(
      id: id,
      manufacturer: id,
      x: x,
      y: y,
      width: w,
      height: h,
      scale: scale,
      rotation: 0,
      refresh: 60,
      resolution: '${w.toInt()}x${h.toInt()}',
      orientation: 'landscape',
      enabled: enabled,
      modes: const [],
      mirrorOf: mirrorOf,
    );

void main() {
  group('findOverlaps', () {
    test('flush neighbours do not count as overlapping', () {
      final mons = [
        _mon(id: 'A', x: 0),
        _mon(id: 'B', x: 1920), // exactly to the right, touching edge
      ];
      expect(LayoutMath.findOverlaps(mons), isEmpty);
    });

    test('sub-pixel touching is tolerated by the epsilon', () {
      final mons = [
        _mon(id: 'A', x: 0),
        _mon(id: 'B', x: 1919.5), // 0.5px overlap — rounding noise
      ];
      expect(LayoutMath.findOverlaps(mons), isEmpty);
    });

    test('a real stack is detected', () {
      final mons = [
        _mon(id: 'A', x: 0),
        _mon(id: 'B', x: 0), // fully on top of A
      ];
      final pairs = LayoutMath.findOverlaps(mons);
      expect(pairs, hasLength(1));
      expect({pairs.first.$1, pairs.first.$2}, equals({'A', 'B'}));
    });

    test('scale is taken into account (logical rects)', () {
      // A 3840-wide panel at scale 2.0 is only 1920 logical px wide, so a
      // neighbour at x=1920 does NOT overlap.
      final mons = [
        _mon(id: 'A', x: 0, w: 3840, scale: 2.0),
        _mon(id: 'B', x: 1920),
      ];
      expect(LayoutMath.findOverlaps(mons), isEmpty);
    });

    test('disabled and mirror outputs are ignored', () {
      final mons = [
        _mon(id: 'A', x: 0),
        _mon(id: 'B', x: 0, enabled: false),
        _mon(id: 'C', x: 0, mirrorOf: 'A'),
      ];
      expect(LayoutMath.findOverlaps(mons), isEmpty);
    });
  });

  group('resolveOverlaps', () {
    test('is a no-op for a clean layout (identity)', () {
      final mons = [
        _mon(id: 'A', x: 0),
        _mon(id: 'B', x: 1920),
      ];
      final out = LayoutMath.resolveOverlaps(mons);
      expect(identical(out, mons), isTrue,
          reason: 'clean layouts must pass through untouched');
    });

    test('repacks overlapping monitors flush, left to right, at y=0', () {
      final mons = [
        _mon(id: 'A', x: 0, w: 1920),
        _mon(id: 'B', x: 100, w: 2560), // overlaps A
        _mon(id: 'C', x: 200, w: 1080), // overlaps both
      ];
      final out = LayoutMath.resolveOverlaps(mons);
      // Ordered by original x: A (0), B (100), C (200).
      final a = out.firstWhere((m) => m.id == 'A');
      final b = out.firstWhere((m) => m.id == 'B');
      final c = out.firstWhere((m) => m.id == 'C');
      expect(a.x, 0);
      expect(a.y, 0);
      expect(b.x, 1920); // flush after A
      expect(c.x, 1920 + 2560); // flush after B
      expect([a.y, b.y, c.y], everyElement(0));
      // And the result itself has no overlaps.
      expect(LayoutMath.findOverlaps(out), isEmpty);
    });

    test('honours scale when repacking', () {
      final mons = [
        _mon(id: 'A', x: 0, w: 3840, scale: 2.0), // 1920 logical
        _mon(id: 'B', x: 0, w: 1920), // stacked on A
      ];
      final out = LayoutMath.resolveOverlaps(mons);
      final b = out.firstWhere((m) => m.id == 'B');
      expect(b.x, 1920, reason: 'flush after A\'s 1920 logical width');
      expect(LayoutMath.findOverlaps(out), isEmpty);
    });

    test('leaves disabled monitors where they are', () {
      final mons = [
        _mon(id: 'A', x: 0),
        _mon(id: 'B', x: 0), // overlaps -> triggers repack
        _mon(id: 'D', x: 5000, enabled: false),
      ];
      final out = LayoutMath.resolveOverlaps(mons);
      final d = out.firstWhere((m) => m.id == 'D');
      expect(d.x, 5000, reason: 'disabled tiles are not repacked');
    });
  });
}
