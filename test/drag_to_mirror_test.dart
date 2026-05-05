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
      mirrorOf: mirrorOf,
    );

void main() {
  group('LayoutMath.detectMirrorDropTarget', () {
    test('returns null when there are no other tiles', () {
      final dragged = _mon(id: 'A');
      expect(
        LayoutMath.detectMirrorDropTarget(dragged: dragged, all: [dragged]),
        isNull,
      );
    });

    test('returns null when the tiles do not overlap at all', () {
      final a = _mon(id: 'A', x: 0);
      final b = _mon(id: 'B', x: 5000);
      expect(
        LayoutMath.detectMirrorDropTarget(dragged: a, all: [a, b]),
        isNull,
      );
    });

    test('returns null when overlap is below the 70% threshold', () {
      // A and B are both 1920×1080 starting at x=0 and x=1500 →
      // overlap width 420, area 420*1080 = 453600, A area = 1920*1080
      // = 2073600, overlap/dragged = 21.9%.
      final a = _mon(id: 'A', x: 0);
      final b = _mon(id: 'B', x: 1500);
      expect(
        LayoutMath.detectMirrorDropTarget(dragged: a, all: [a, b]),
        isNull,
      );
    });

    test('detects a centered drop with full overlap', () {
      final a = _mon(id: 'A', x: 0);
      final b = _mon(id: 'B', x: 0);
      final hit = LayoutMath.detectMirrorDropTarget(dragged: a, all: [a, b]);
      expect(hit, isNotNull);
      expect(hit!.id, 'B');
    });

    test('detects a partial drop just above the 70% threshold', () {
      // Same dimensions; A shifted right by 500 px → overlap is
      // 1420*1080 = 1533600 / 1920*1080 = 73.96% of dragged.
      final a = _mon(id: 'A', x: 500);
      final b = _mon(id: 'B', x: 0);
      expect(
        LayoutMath.detectMirrorDropTarget(dragged: a, all: [a, b]),
        isNotNull,
      );
    });

    test('skips disabled tiles as drop targets', () {
      final a = _mon(id: 'A', x: 0);
      final b = _mon(id: 'B', x: 0, enabled: false);
      expect(
        LayoutMath.detectMirrorDropTarget(dragged: a, all: [a, b]),
        isNull,
      );
    });

    test('skips mirror-destination tiles as drop targets', () {
      // B is itself a destination — its physical screen runs C's pixels.
      // Dropping A onto B's logical rect would land on a phantom (B is
      // filtered out of the layout), so we refuse the suggestion.
      final a = _mon(id: 'A', x: 0);
      final b = _mon(id: 'B', x: 0, mirrorOf: 'C');
      expect(
        LayoutMath.detectMirrorDropTarget(dragged: a, all: [a, b]),
        isNull,
      );
    });

    test('refuses to suggest when the dragged tile is a destination', () {
      // A's drag is supposed to be disabled by the tile widget already,
      // but the geometry guard is still cheaper than relying on that.
      final a = _mon(id: 'A', x: 0, mirrorOf: 'X');
      final b = _mon(id: 'B', x: 0);
      expect(
        LayoutMath.detectMirrorDropTarget(dragged: a, all: [a, b]),
        isNull,
      );
    });

    test('picks the candidate with the largest absolute overlap', () {
      // A overlaps both B and C; B is fully covered (1920×1080 = full
      // overlap), C is half-covered (960×1080). Pick B.
      final a = _mon(id: 'A', x: 0, w: 1920, h: 1080);
      final b = _mon(id: 'B', x: 0, w: 1920, h: 1080);
      final c = _mon(id: 'C', x: 1920, w: 1920, h: 1080);
      final hit =
          LayoutMath.detectMirrorDropTarget(dragged: a, all: [a, b, c]);
      expect(hit, isNotNull);
      expect(hit!.id, 'B');
    });

    test('respects the overlapThreshold parameter', () {
      // Same as the "below 70%" case (~22% overlap) but with a 0.1
      // threshold the function should accept it.
      final a = _mon(id: 'A', x: 0);
      final b = _mon(id: 'B', x: 1500);
      expect(
        LayoutMath.detectMirrorDropTarget(
          dragged: a,
          all: [a, b],
          overlapThreshold: 0.1,
        ),
        isNotNull,
      );
    });

    test('handles a 2x scaled dragged tile in logical coordinates', () {
      // 4K panel at scale 2 has logical extent 1920x1080 — should be
      // overlap-equivalent to a 1080p tile of the same logical size.
      final dragged = _mon(id: 'A', x: 0, w: 3840, h: 2160, scale: 2.0);
      final target = _mon(id: 'B', x: 0, w: 1920, h: 1080, scale: 1.0);
      final hit = LayoutMath.detectMirrorDropTarget(
        dragged: dragged,
        all: [dragged, target],
      );
      expect(hit, isNotNull);
      expect(hit!.id, 'B');
    });
  });
}
