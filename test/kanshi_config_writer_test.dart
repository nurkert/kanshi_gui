import 'package:flutter_test/flutter_test.dart';
import 'package:kanshi_gui/models/monitor_tile_data.dart';
import 'package:kanshi_gui/models/profiles.dart';
import 'package:kanshi_gui/services/kanshi_config_parser.dart';
import 'package:kanshi_gui/services/kanshi_config_writer.dart';

MonitorTileData _mon({
  String id = 'M',
  double x = 0,
  double y = 0,
  double w = 1920,
  double h = 1080,
  double scale = 1.0,
  bool enabled = true,
  int rotation = 0,
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
    rotation: rotation,
    refresh: refresh,
    resolution: '${w.toInt()}x${h.toInt()}',
    orientation: w >= h ? 'landscape' : 'portrait',
    enabled: enabled,
  );
}

void main() {
  group('KanshiConfigWriter.render — neutral defaults', () {
    test('does not emit Sway-specific exec lines by default', () {
      final p = Profile(name: 'X', monitors: [_mon(id: 'A')]);
      final out = KanshiConfigWriter.render([p]);
      expect(out, isNot(contains('exec swaymsg')));
      expect(out, isNot(contains('current_kanshi_profile')));
    });

    test('renders an enabled output with the expected fields', () {
      final p = Profile(name: 'Desk', monitors: [_mon(id: 'eDP-1')]);
      final out = KanshiConfigWriter.render([p]);
      expect(out, contains("profile 'Desk' {"));
      expect(out,
          contains("output 'eDP-1' enable scale 1.00 mode 1920x1080@60Hz "
              "transform normal position 0,0"));
    });

    test('emits `disable` line for disabled outputs', () {
      final p = Profile(
        name: 'X',
        monitors: [_mon(id: 'eDP-1', enabled: false)],
      );
      final out = KanshiConfigWriter.render([p]);
      expect(out, contains("output 'eDP-1' disable"));
    });

    test('skips profiles without monitors', () {
      final out = KanshiConfigWriter.render([Profile(name: 'X', monitors: [])]);
      expect(out.trim(), isEmpty);
    });
  });

  group('KanshiConfigWriter.render — Sway extras', () {
    test('emits workspace exec lines when injectSwayWorkspaceExec is true', () {
      final p = Profile(
        name: 'P',
        monitors: [_mon(id: 'A'), _mon(id: 'B', x: 1920)],
      );
      final out = KanshiConfigWriter.render(
        [p],
        options: KanshiWriteOptions.swayDefaults,
      );
      expect(out, contains('exec swaymsg'));
      expect(out, contains("current_kanshi_profile"));
    });
  });

  group('Round-trip: writer → parser', () {
    test('preserves monitor count and properties for a 2-monitor profile', () {
      final p = Profile(
        name: 'Desk',
        monitors: [
          _mon(id: 'A', x: 0, y: 0, w: 2560, h: 1440),
          _mon(id: 'B', x: 2560, y: 0, w: 1920, h: 1080, scale: 1.5),
        ],
      );
      final rendered = KanshiConfigWriter.render([p]);
      final reparsed = KanshiConfigParser.parse(rendered);

      expect(reparsed, hasLength(1));
      expect(reparsed.first.name, equals('Desk'));
      expect(reparsed.first.monitors, hasLength(2));
      expect(reparsed.first.monitors.map((m) => m.id).toSet(),
          equals({'A', 'B'}));

      final b =
          reparsed.first.monitors.firstWhere((m) => m.id == 'B');
      expect(b.scale, equals(1.5));
    });

    test('round-trips a rotated portrait monitor', () {
      final p = Profile(
        name: 'Vert',
        monitors: [_mon(id: 'A', w: 2560, h: 1440, rotation: 90)],
      );
      final rendered = KanshiConfigWriter.render([p]);
      final m = KanshiConfigParser.parse(rendered).single.monitors.single;
      expect(m.rotation, equals(90));
      expect(m.width, equals(1440));
      expect(m.height, equals(2560));
    });
  });
}
