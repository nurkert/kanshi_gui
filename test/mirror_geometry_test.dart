import 'package:flutter_test/flutter_test.dart';
import 'package:kanshi_gui/domain/mirror_geometry.dart';
import 'package:kanshi_gui/models/monitor_tile_data.dart';

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
  group('isInternalPanel', () {
    test('recognises the DRM connector names of built-in panels', () {
      expect(MirrorGeometry.isInternalPanel('eDP-1'), isTrue);
      expect(MirrorGeometry.isInternalPanel('LVDS-1'), isTrue);
      expect(MirrorGeometry.isInternalPanel('DSI-1'), isTrue);
      expect(MirrorGeometry.isInternalPanel('DP-1'), isFalse);
      expect(MirrorGeometry.isInternalPanel('HDMI-A-2'), isFalse);
      expect(MirrorGeometry.isInternalPanel('Samsung TV'), isFalse);
    });
  });

  group('preferredSource', () {
    test('the built-in panel wins even when it is not leftmost', () {
      // The presentation case: laptop on the right of the canvas because
      // that is where it was captured, television on the left. "Mirror"
      // must still mean "the television shows the laptop".
      final tv = _mon(id: 'DP-1', x: 0);
      final laptop = _mon(id: 'eDP-1', x: 3000);
      expect(MirrorGeometry.preferredSource([tv, laptop])!.id, 'eDP-1');
    });

    test('without a built-in panel the leftmost screen is the source', () {
      final a = _mon(id: 'DP-2', x: 2560);
      final b = _mon(id: 'DP-1', x: 0);
      expect(MirrorGeometry.preferredSource([a, b])!.id, 'DP-1');
    });

    test('empty input has no answer', () {
      expect(MirrorGeometry.preferredSource(const []), isNull);
    });
  });

  group('withDetachedDestinations', () {
    test('a destination lands a pointer gap right of the independent screens',
        () {
      final laptop = _mon(id: 'eDP-1', x: 0, y: 180);
      final ext = _mon(id: 'DP-2', x: 1920, y: 0, w: 2560, h: 1440);
      final tv = _mon(id: 'DP-1', x: 1920, y: 0, mirrorOf: 'eDP-1');
      final placed =
          MirrorGeometry.withDetachedDestinations([laptop, ext, tv]);
      final placedTv = placed.firstWhere((m) => m.id == 'DP-1');
      expect(placedTv.x, 1920 + 2560 + MirrorGeometry.pointerGap);
      expect(placedTv.y, 0, reason: 'aligned with the top of the cluster');
      // The independent screens are untouched.
      expect(placed.firstWhere((m) => m.id == 'eDP-1').x, 0);
      expect(placed.firstWhere((m) => m.id == 'DP-2').x, 1920);
    });

    test('the cluster edge is measured in logical pixels', () {
      // A HiDPI source at scale 2 is half as wide on the layout as its mode
      // says; the gap has to start where the logical rectangle ends.
      final hidpi = _mon(id: 'eDP-1', w: 3840, h: 2160, scale: 2.0);
      final tv = _mon(id: 'DP-1', mirrorOf: 'eDP-1');
      final placed = MirrorGeometry.withDetachedDestinations([hidpi, tv]);
      expect(placed.last.x, 1920 + MirrorGeometry.pointerGap);
    });

    test('two destinations do not overlap each other', () {
      final src = _mon(id: 'eDP-1');
      final a = _mon(id: 'DP-1', mirrorOf: 'eDP-1');
      final b = _mon(id: 'DP-2', mirrorOf: 'eDP-1', h: 1440, w: 2560);
      final placed = MirrorGeometry.withDetachedDestinations([src, a, b]);
      final pa = placed[1];
      final pb = placed[2];
      expect(pa.x, pb.x);
      expect(pb.y, greaterThanOrEqualTo(pa.y + 1080),
          reason: 'stacked below the first destination');
    });

    test('a layout without destinations passes through untouched', () {
      final mons = [_mon(id: 'A'), _mon(id: 'B', x: 1920)];
      expect(MirrorGeometry.withDetachedDestinations(mons), same(mons));
    });

    test('a disabled destination keeps its own position', () {
      final src = _mon(id: 'eDP-1');
      final off = _mon(id: 'DP-1', x: 5, enabled: false, mirrorOf: 'eDP-1');
      final placed = MirrorGeometry.withDetachedDestinations([src, off]);
      expect(placed.last.x, 5);
    });
  });

  group('rejoined', () {
    test('a released destination is placed flush right of the others', () {
      // After a config reload the model may carry the detached position;
      // releasing the mirror must bring the screen back next to the rest.
      final laptop = _mon(id: 'eDP-1', x: 0, y: 180);
      final far = _mon(id: 'DP-1', x: 1920 + MirrorGeometry.pointerGap, y: 0);
      final back = MirrorGeometry.rejoined(far, [laptop, far]);
      expect(back.x, 1920);
      expect(back.y, 180);
    });

    test('a screen that still sits next to the others keeps its place', () {
      // The model keeps the pre-mirror position; a screen that was LEFT of
      // the laptop must not jump to the right when the mirror is released.
      final laptop = _mon(id: 'eDP-1', x: 1920);
      final ext = _mon(id: 'DP-1', x: 0);
      expect(MirrorGeometry.rejoined(ext, [laptop, ext]).x, 0);
    });

    test('with nothing to rejoin the position is kept', () {
      final alone = _mon(id: 'DP-1', x: 42);
      expect(MirrorGeometry.rejoined(alone, [alone]).x, 42);
    });
  });
}
