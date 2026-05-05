// Goldens that lock in the coordinate-system contract documented on
// `MonitorTileData`: x/y live in **logical** layout pixels (post-scale),
// width/height are the **physical** mode dimensions, and scale is the
// per-output HiDPI factor. Sway's `output position X Y` IPC and kanshi's
// config syntax both consume logical layout coordinates, so a layout
// with mixed scales must produce positions that match `x`/`y` verbatim
// after the writer/apply pipeline — no extra `* scale` or `/ scale`
// conversions on the way out.

import 'package:flutter_test/flutter_test.dart';
import 'package:kanshi_gui/models/monitor_mode.dart';
import 'package:kanshi_gui/models/monitor_tile_data.dart';
import 'package:kanshi_gui/models/profiles.dart';
import 'package:kanshi_gui/services/backends/sway_backend.dart';
import 'package:kanshi_gui/services/kanshi_config_parser.dart';
import 'package:kanshi_gui/services/kanshi_config_writer.dart';
import 'package:kanshi_gui/services/layout_math.dart';

import 'fakes/fake_process_runner.dart';

MonitorTileData _mon({
  required String id,
  required double x,
  double y = 0,
  required double w,
  required double h,
  required double scale,
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
      modes: [MonitorMode(width: w, height: h, refresh: 60)],
    );

void main() {
  group('mixed-scale (1× + 2×) layout', () {
    // 1080p panel at scale 1.0 (logical 1920×1080) flush-left of a 4K
    // panel at scale 2.0 (logical 1920×1080). The 4K's logical extent
    // is 3840 / 2.0 = 1920; sat at x = 1920 it fills logical x = 1920..3840.
    final pair = [
      _mon(id: 'HD', x: 0, w: 1920, h: 1080, scale: 1.0),
      _mon(id: '4K', x: 1920, w: 3840, h: 2160, scale: 2.0),
    ];

    test('boundingBox returns the logical layout extent', () {
      final bbox = LayoutMath.boundingBox(pair);
      expect(bbox.left, equals(0));
      expect(bbox.top, equals(0));
      // Logical: 1920 (HD) + 1920 (4K @ scale 2) = 3840.
      expect(bbox.right, equals(3840));
      expect(bbox.bottom, equals(1080));
    });

    test('writer emits position arguments in logical coords', () {
      final cfg = KanshiConfigWriter.render(
        [Profile(name: 'mixed', monitors: pair)],
      );
      // The 4K monitor's position should be `1920,0` in logical pixels —
      // not `3840,0` (which is what double-applying the scale would yield).
      expect(
        cfg,
        contains("output '4K' enable scale 2.00 mode 3840x2160@60Hz "
            "transform normal position 1920,0"),
      );
      expect(
        cfg,
        contains("output 'HD' enable scale 1.00 mode 1920x1080@60Hz "
            "transform normal position 0,0"),
      );
    });

    test('writer→parser round-trips logical positions', () {
      final rendered = KanshiConfigWriter.render(
        [Profile(name: 'mixed', monitors: pair)],
      );
      final parsed = KanshiConfigParser.parse(rendered).single.monitors;
      final hd = parsed.firstWhere((m) => m.id == 'HD');
      final fourK = parsed.firstWhere((m) => m.id == '4K');
      expect(hd.x, equals(0));
      expect(fourK.x, equals(1920),
          reason: 'Logical 1920 must survive a write/parse cycle unchanged.');
    });

    test('SwayBackend.apply emits logical position to swaymsg', () async {
      final runner = FakeProcessRunner(installed: {'swaymsg'});
      final backend = SwayBackend(runner: runner);
      await backend.apply(pair[1]); // the 4K
      // The last recorded call is the apply invocation we care about.
      // Find it by scanning for the position arguments.
      final applyCall = runner.calls.firstWhere(
        (call) => call.contains('position'),
        orElse: () => const <String>[],
      );
      expect(applyCall, isNotEmpty,
          reason: 'apply() must emit a "position" argument.');
      final posIdx = applyCall.indexOf('position');
      // position is followed by two integer arguments: X then Y.
      expect(applyCall[posIdx + 1], equals('1920'),
          reason: 'Sway position X must equal the logical x stored on the '
              'tile, not x * scale or x / scale.');
      expect(applyCall[posIdx + 2], equals('0'));
    });

    test('apply also emits the physical mode dimensions, not logical', () async {
      final runner = FakeProcessRunner(installed: {'swaymsg'});
      final backend = SwayBackend(runner: runner);
      await backend.apply(pair[1]);
      final applyCall = runner.calls.firstWhere(
        (call) => call.any((a) => a.contains('@')),
        orElse: () => const <String>[],
      );
      final modeArg = applyCall.firstWhere((a) => a.contains('@'),
          orElse: () => '');
      // Mode must be the panel's physical resolution (3840x2160), not
      // the logical extent (1920x1080).
      expect(modeArg, contains('3840x2160'),
          reason: 'mode … is the physical panel mode, not the logical extent.');
    });
  });

  group('uniform-scale layout (regression guard)', () {
    final pair = [
      _mon(id: 'A', x: 0, w: 1920, h: 1080, scale: 1.0),
      _mon(id: 'B', x: 1920, w: 1920, h: 1080, scale: 1.0),
    ];

    test('boundingBox is identical to the physical sum at scale 1.0', () {
      final bbox = LayoutMath.boundingBox(pair);
      expect(bbox.right, equals(3840));
    });
  });
}
