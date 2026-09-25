import 'package:flutter_test/flutter_test.dart';
import 'package:kanshi_gui/models/monitor_tile_data.dart';

MonitorTileData _panel() => MonitorTileData(
      id: 'DP-4',
      manufacturer: 'Dell Inc. U2720Q X',
      edidDescriptor: 'Dell Inc. U2720Q X',
      x: 100,
      y: 50,
      width: 2560,
      height: 1440,
      rotation: 0,
      refresh: 60,
      resolution: '2560x1440',
      orientation: 'landscape',
      mirrorOf: 'eDP-1',
      workspaceRank: 2,
    );

void main() {
  group('withRotation', () {
    test('turning to portrait turns the rectangle too', () {
      final m = _panel().withRotation(90);
      expect(m.rotation, 90);
      expect((m.width, m.height), (1440.0, 2560.0));
      expect(m.orientation, 'portrait');
      expect(m.resolution, '2560x1440', reason: 'the native mode does not turn');
    });

    test('half a turn keeps the shape', () {
      final m = _panel().withRotation(180);
      expect((m.width, m.height), (2560.0, 1440.0));
      expect(m.orientation, 'landscape');
    });

    test('portrait to portrait keeps the shape', () {
      final m = _panel().withRotation(90).withRotation(270);
      expect((m.width, m.height), (1440.0, 2560.0));
    });

    test('the picker, then a right-click, ends where the screen is', () {
      // The bug: the picker under the canvas set 90° without turning the
      // tile, and the right-click after it turned the tile the wrong way.
      final picked = _panel().withRotation(90);
      final clicked = picked.withRotation(picked.rotation + 90);
      expect(clicked.rotation, 180);
      expect((clicked.width, clicked.height), (2560.0, 1440.0));
      expect(clicked.orientation, 'landscape');
    });

    test('nothing else about the screen is lost', () {
      final m = _panel().withRotation(270);
      expect(m.x, 100);
      expect(m.y, 50);
      expect(m.edidDescriptor, 'Dell Inc. U2720Q X');
      expect(m.mirrorOf, 'eDP-1');
      expect(m.workspaceRank, 2);
    });
  });
}
