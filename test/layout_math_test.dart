import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:kanshi_gui/models/monitor_tile_data.dart';
import 'package:kanshi_gui/services/layout_math.dart';

MonitorTileData _mon({
  String id = 'M',
  double x = 0,
  double y = 0,
  double w = 1920,
  double h = 1080,
  double scale = 1.0,
  bool enabled = true,
  double refresh = 60,
}) {
  return MonitorTileData(
    id: id,
    manufacturer: id,
    x: x,
    y: y,
    width: w,
    height: h,
    scale: scale,
    rotation: 0,
    refresh: refresh,
    resolution: '${w.toInt()}x${h.toInt()}',
    orientation: w >= h ? 'landscape' : 'portrait',
    enabled: enabled,
  );
}

void main() {
  group('LayoutMath.snapToEdges', () {
    test('snaps left edge of B to right edge of A within threshold', () {
      final a = _mon(id: 'A', x: 0, y: 0);
      final b = _mon(id: 'B', x: 1925, y: 0); // 5 px to the right of A
      final snapped = LayoutMath.snapToEdges(b, [a, b], 50);
      expect(snapped.x, equals(1920));
      expect(snapped.y, equals(0));
    });

    test('does not move when no neighbour is within threshold', () {
      final a = _mon(id: 'A', x: 0, y: 0);
      final b = _mon(id: 'B', x: 4000, y: 200);
      final snapped = LayoutMath.snapToEdges(b, [a, b], 50);
      expect(snapped.x, equals(4000));
      expect(snapped.y, equals(200));
    });

    test('snaps top edge of B to bottom edge of A', () {
      final a = _mon(id: 'A', x: 0, y: 0);
      final b = _mon(id: 'B', x: 0, y: 1100); // 20 px below A
      final snapped = LayoutMath.snapToEdges(b, [a, b], 50);
      expect(snapped.y, equals(1080));
    });

    test('respects scale when computing edges', () {
      final a = _mon(id: 'A', x: 0, y: 0, w: 3840, h: 2160, scale: 2.0);
      // A's right edge in logical coords is 3840/2 = 1920
      final b = _mon(id: 'B', x: 1925, y: 0);
      final snapped = LayoutMath.snapToEdges(b, [a, b], 50);
      expect(snapped.x, equals(1920));
    });
  });

  group('LayoutMath.hasOverlap', () {
    test('detects overlap of two co-located monitors', () {
      final a = _mon(id: 'A', x: 0, y: 0);
      final b = _mon(id: 'B', x: 100, y: 100);
      final list = [a, b];
      expect(LayoutMath.hasOverlap(b, list, 1), isTrue);
    });

    test('does not flag perfectly adjacent monitors', () {
      final a = _mon(id: 'A', x: 0, y: 0);
      final b = _mon(id: 'B', x: 1920, y: 0);
      final list = [a, b];
      expect(LayoutMath.hasOverlap(b, list, 1), isFalse);
    });

    test('honours scale when forming rectangles', () {
      final a = _mon(id: 'A', x: 0, y: 0, w: 3840, h: 2160, scale: 2.0);
      // A spans logical 1920×1080. B at 1920,0 should not overlap.
      final b = _mon(id: 'B', x: 1920, y: 0);
      final list = [a, b];
      expect(LayoutMath.hasOverlap(b, list, 1), isFalse);
    });
  });

  group('LayoutMath.computeDisplay', () {
    test('returns empty layout for an empty input', () {
      final l = LayoutMath.computeDisplay([], const Size(800, 600));
      expect(l.displayMonitors, isEmpty);
      expect(l.scaleFactor, equals(1.0));
    });

    test('fits two side-by-side monitors into the viewport (centered)', () {
      final a = _mon(id: 'A', x: 0, y: 0); // 1920×1080
      final b = _mon(id: 'B', x: 1920, y: 0);
      final l = LayoutMath.computeDisplay([a, b], const Size(800, 600));

      // Viewport allows 80 % → 640 wide. Bounding is 3840 wide.
      // Expected scale = 640/3840 = 0.1666…
      expect(l.scaleFactor, closeTo(640 / 3840, 1e-6));

      // Both tiles together should be horizontally centered.
      final left = l.displayMonitors.first.x;
      final right = l.displayMonitors.last.x + l.displayMonitors.last.width;
      expect(((left + right) / 2), closeTo(400, 1e-3));
    });

    test('never up-scales above 1.0', () {
      final a = _mon(id: 'A', x: 0, y: 0, w: 100, h: 100);
      final l = LayoutMath.computeDisplay([a], const Size(4000, 4000));
      expect(l.scaleFactor, equals(1.0));
    });
  });

  group('LayoutMath.totalPixelRate', () {
    test('sums width × height × refresh of enabled monitors only', () {
      final a = _mon(id: 'A', w: 1920, h: 1080, refresh: 60);
      final b = _mon(id: 'B', w: 2560, h: 1440, refresh: 144);
      final disabled = _mon(
          id: 'C', w: 3840, h: 2160, refresh: 60, enabled: false);
      final rate = LayoutMath.totalPixelRate([a, b, disabled]);
      expect(rate, equals(1920.0 * 1080 * 60 + 2560.0 * 1440 * 144));
    });

    test('falls back to 60 Hz when refresh is non-positive', () {
      final m = _mon(refresh: 0);
      expect(LayoutMath.totalPixelRate([m]),
          equals(1920.0 * 1080 * 60));
    });
  });
}
