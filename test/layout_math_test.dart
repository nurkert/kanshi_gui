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
  String? mirrorOf,
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
    mirrorOf: mirrorOf,
  );
}

void main() {
  group('LayoutMath.snapToEdges', () {
    test('snaps left edge of B to right edge of A within threshold', () {
      final a = _mon(id: 'A', x: 0, y: 0);
      final b = _mon(id: 'B', x: 1925, y: 0); // 5 px to the right of A
      final r = LayoutMath.snapToEdges(b, [a, b], 50);
      expect(r.tile.x, equals(1920));
      expect(r.tile.y, equals(0));
      expect(r.activeLines, isNotEmpty);
    });

    test('does not move when no neighbour is within threshold', () {
      final a = _mon(id: 'A', x: 0, y: 0);
      final b = _mon(id: 'B', x: 4000, y: 200);
      final r = LayoutMath.snapToEdges(b, [a, b], 50);
      expect(r.tile.x, equals(4000));
      expect(r.tile.y, equals(200));
      expect(r.activeLines, isEmpty);
    });

    test('snaps top edge of B to bottom edge of A', () {
      final a = _mon(id: 'A', x: 0, y: 0);
      final b = _mon(id: 'B', x: 0, y: 1100); // 20 px below A
      final r = LayoutMath.snapToEdges(b, [a, b], 50);
      expect(r.tile.y, equals(1080));
    });

    test('respects scale when computing edges', () {
      final a = _mon(id: 'A', x: 0, y: 0, w: 3840, h: 2160, scale: 2.0);
      // A's right edge in logical coords is 3840/2 = 1920
      final b = _mon(id: 'B', x: 1925, y: 0);
      final r = LayoutMath.snapToEdges(b, [a, b], 50);
      expect(r.tile.x, equals(1920));
    });

    test('snaps Y to top-aligned when X edge is engaged', () {
      // A is 1920×1080 at (0,0). B is 1920×800 dropped at (1925, 8) — X
      // edge snaps and Y is within threshold of top alignment.
      final a = _mon(id: 'A', x: 0, y: 0);
      final b = _mon(id: 'B', x: 1925, y: 8, w: 1920, h: 800);
      final r = LayoutMath.snapToEdges(b, [a, b], 50);
      expect(r.tile.x, equals(1920));
      expect(r.tile.y, equals(0));
      expect(r.activeLines.length, equals(2));
    });

    test('snaps Y to center-aligned when X edge is engaged', () {
      final a = _mon(id: 'A', x: 0, y: 0); // height 1080, center 540
      final b = _mon(id: 'B', x: 1925, y: 145, w: 1920, h: 800);
      // B center would be at y + 400 = 545 → 5 px off centre 540, within 50
      final r = LayoutMath.snapToEdges(b, [a, b], 50);
      expect(r.tile.x, equals(1920));
      expect(r.tile.y, equals(140)); // center: 540 - 400 = 140
    });

    test('does not Y-snap when X is not snapped', () {
      // B's X is far from A's edges → no X snap, so no Y alignment kicks in.
      final a = _mon(id: 'A', x: 0, y: 0);
      final b = _mon(id: 'B', x: 5000, y: 8);
      final r = LayoutMath.snapToEdges(b, [a, b], 50);
      expect(r.tile.y, equals(8));
      expect(r.activeLines, isEmpty);
    });

    test('yAlignmentEnabled=false keeps the edge snap but skips Y-align', () {
      final a = _mon(id: 'A', x: 0, y: 0);
      // Same Y as the X-edge alignment scenario, but alignment off.
      final b = _mon(id: 'B', x: 1925, y: 8, w: 1920, h: 800);
      final r = LayoutMath.snapToEdges(b, [a, b], 50,
          yAlignmentEnabled: false);
      // Edge still snaps.
      expect(r.tile.x, equals(1920));
      expect(r.xEdgeSnapped, isTrue);
      // Y stays where the user put it; no alignment applied.
      expect(r.tile.y, equals(8));
      expect(r.yAlignmentApplied, isFalse);
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

    test('exposes the origin used for projection', () {
      // The carry-on origin lets snap-line painters and drag-end coordinate
      // translation project against the same point the tiles were projected
      // from — without recomputing min(monitors), which would be wrong while
      // bounds are pinned.
      final a = _mon(id: 'A', x: -200, y: -50);
      final b = _mon(id: 'B', x: 1920, y: 0);
      final l = LayoutMath.computeDisplay([a, b], const Size(800, 600));
      expect(l.originX, equals(-200));
      expect(l.originY, equals(-50));
    });

    test('pinnedBounds overrides the auto bounding box', () {
      final a = _mon(id: 'A', x: 0, y: 0); // 1920×1080
      final b = _mon(id: 'B', x: 1920, y: 0);
      final pinned = Rect.fromLTRB(0, 0, 3840, 1080);
      // Move B off into negative space — without the pin this would shift
      // origin and reflow the layout. With the pin, origin stays at (0,0)
      // and the unmoved tile A keeps the exact same viewport projection.
      final moved = b.copyWith(x: -500, y: -500);
      final unpinned =
          LayoutMath.computeDisplay([a, b], const Size(800, 600));
      final pinnedLayout = LayoutMath.computeDisplay(
        [a, moved],
        const Size(800, 600),
        pinnedBounds: pinned,
      );
      expect(pinnedLayout.originX, equals(0));
      expect(pinnedLayout.originY, equals(0));
      expect(pinnedLayout.scaleFactor, equals(unpinned.scaleFactor));
      expect(pinnedLayout.offsetX, equals(unpinned.offsetX));
      expect(pinnedLayout.offsetY, equals(unpinned.offsetY));
      // A — the tile that didn't move — must project to the same viewport
      // position. This is the core property: the canvas does not reflow
      // under the dragged tile.
      final aPinned =
          pinnedLayout.displayMonitors.firstWhere((m) => m.id == 'A');
      final aUnpinned =
          unpinned.displayMonitors.firstWhere((m) => m.id == 'A');
      expect(aPinned.x, equals(aUnpinned.x));
      expect(aPinned.y, equals(aUnpinned.y));
    });
  });

  group('LayoutMath.computeDisplay disabled-tile parking', () {
    test('parks a disabled monitor to the right of the active cluster', () {
      // Sway leaves disabled outputs at (0, 0). Without parking they would
      // render on top of the monitor that actually occupies origin.
      final active = _mon(id: 'A', x: 0, y: 0); // 1920×1080
      final off = _mon(id: 'B', x: 0, y: 0, enabled: false);
      final l = LayoutMath.computeDisplay([active, off], const Size(800, 600));
      final aTile = l.displayMonitors.firstWhere((m) => m.id == 'A');
      final bTile = l.displayMonitors.firstWhere((m) => m.id == 'B');
      // Disabled tile must be entirely to the right of the active tile.
      expect(bTile.x, greaterThan(aTile.x + aTile.width),
          reason: 'Disabled tile must not overlap the active cluster.');
    });

    test('stacks multiple disabled monitors vertically in the park lane', () {
      final active = _mon(id: 'A', x: 0, y: 0);
      final b = _mon(id: 'B', x: 0, y: 0, enabled: false);
      final c = _mon(id: 'C', x: 0, y: 0, enabled: false);
      final l = LayoutMath.computeDisplay(
          [active, b, c], const Size(800, 600));
      final bTile = l.displayMonitors.firstWhere((m) => m.id == 'B');
      final cTile = l.displayMonitors.firstWhere((m) => m.id == 'C');
      // Same park column.
      expect(cTile.x, equals(bTile.x));
      // C below B (no overlap, with a gap).
      expect(cTile.y, greaterThan(bTile.y + bTile.height));
    });

    test('mirror destinations are absorbed into the source tile', () {
      // Both physical screens show the same pixels, so the layout shows
      // only the source tile. mirroredBy reports the relationship so the
      // UI can paint the cyan badge.
      final active = _mon(id: 'A', x: 0, y: 0);
      final mirror = _mon(id: 'B', x: 0, y: 0, mirrorOf: 'A');
      final off = _mon(id: 'C', x: 0, y: 0, enabled: false);
      final l = LayoutMath.computeDisplay(
          [active, mirror, off], const Size(800, 600));
      expect(l.displayMonitors.map((m) => m.id), isNot(contains('B')),
          reason: 'Mirror destination must be filtered out of the layout.');
      expect(l.displayMonitors.map((m) => m.id),
          containsAll(['A', 'C']));
      expect(l.mirroredBy, equals({'A': ['B']}));
      // The disabled tile still parks beside A — no mirror lane.
      final aTile = l.displayMonitors.firstWhere((m) => m.id == 'A');
      final cTile = l.displayMonitors.firstWhere((m) => m.id == 'C');
      expect(cTile.x, greaterThan(aTile.x + aTile.width),
          reason: 'Disabled tile parked to the right of the active cluster.');
    });

    test('multiple destinations on one source aggregate in mirroredBy', () {
      final active = _mon(id: 'A', x: 0, y: 0);
      final b = _mon(id: 'B', x: 0, y: 0, mirrorOf: 'A');
      final c = _mon(id: 'C', x: 0, y: 0, mirrorOf: 'A');
      final l = LayoutMath.computeDisplay(
          [active, b, c], const Size(800, 600));
      expect(l.displayMonitors.map((m) => m.id), equals(['A']));
      expect(l.mirroredBy['A'], unorderedEquals(['B', 'C']));
    });

    test('all-disabled layouts keep the original positions', () {
      // Nothing to park beside — fall back to honouring stored coords so
      // the user still sees their last known layout instead of a single
      // collapsed tile.
      final a = _mon(id: 'A', x: 0, y: 0, enabled: false);
      final b = _mon(id: 'B', x: 1920, y: 0, enabled: false);
      final l = LayoutMath.computeDisplay([a, b], const Size(800, 600));
      // Two distinct tile positions (not stacked at origin).
      final aTile = l.displayMonitors.firstWhere((m) => m.id == 'A');
      final bTile = l.displayMonitors.firstWhere((m) => m.id == 'B');
      expect(bTile.x, greaterThan(aTile.x));
    });
  });

  group('LayoutMath.boundingBox', () {
    test('returns Rect.zero for empty input', () {
      expect(LayoutMath.boundingBox(const []), equals(Rect.zero));
    });

    test('matches the auto bounding box computeDisplay derives', () {
      final a = _mon(id: 'A', x: 0, y: 0);
      final b = _mon(id: 'B', x: 1920, y: 1080);
      final box = LayoutMath.boundingBox([a, b]);
      expect(box, equals(const Rect.fromLTRB(0, 0, 3840, 2160)));
    });

    test('honours scale (logical edges) not raw pixel edges', () {
      final a = _mon(id: 'A', x: 0, y: 0, w: 3840, h: 2160, scale: 2.0);
      final box = LayoutMath.boundingBox([a]);
      expect(box, equals(const Rect.fromLTRB(0, 0, 1920, 1080)));
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
