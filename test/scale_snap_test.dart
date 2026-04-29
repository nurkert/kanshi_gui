import 'package:flutter_test/flutter_test.dart';
import 'package:kanshi_gui/models/monitor_tile_data.dart';
import 'package:kanshi_gui/services/config_service.dart';
import 'package:kanshi_gui/services/kanshi_config_writer.dart';
import 'package:kanshi_gui/state/kanshi_controller.dart';

import 'fakes/fake_monitor_service.dart';

MonitorTileData _mon({
  String id = 'A',
  double x = 0,
  double y = 0,
  double w = 1920,
  double h = 1080,
  double scale = 1.0,
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
    );

Future<KanshiController> _ctrl() async {
  final cfg = ConfigService(
    configPath: '/tmp/kanshi_gui_test_${DateTime.now().microsecondsSinceEpoch}',
    backupPath: '/tmp/kanshi_gui_test_bak_${DateTime.now().microsecondsSinceEpoch}',
    writeOptions: KanshiWriteOptions.neutral,
  );
  final fake = FakeMonitorService(outputs: [_mon(id: 'A')]);
  final c = KanshiController(monitors: fake, config: cfg);
  await c.init();
  // Replace any auto-created profile with a deterministic one.
  c.deleteProfile(0);
  // Fresh state: add a profile manually.
  c.createProfileFromCurrentSetup();
  return c;
}

void main() {
  test('scale during drag keeps the raw value (no snap glue at 1.0)',
      () async {
    final c = await _ctrl();
    c.scaleMonitor('A', 1.02); // committing=false
    expect(c.activeMonitors.first.scale, equals(1.02));
  });

  test('scale on commit rasters onto nearest snap value within tolerance',
      () async {
    final c = await _ctrl();
    c.scaleMonitor('A', 1.48, committing: true);
    expect(c.activeMonitors.first.scale, equals(1.5));
  });

  test('scale on commit leaves value untouched outside tolerance',
      () async {
    final c = await _ctrl();
    c.scaleMonitor('A', 1.4, committing: true); // |1.4-1.333|=0.067 > 0.03
    expect(c.activeMonitors.first.scale, equals(1.4));
  });

  test('does not re-snap to the value just left without 2x tolerance gap',
      () async {
    final c = await _ctrl();
    // First commit: snaps to 1.5.
    c.scaleMonitor('A', 1.5, committing: true);
    expect(c.activeMonitors.first.scale, equals(1.5));
    // User nudges away by 0.02 (within 2x tolerance) → must NOT snap back.
    c.scaleMonitor('A', 1.52, committing: true);
    expect(c.activeMonitors.first.scale, equals(1.52));
  });

  test('integer scales > 3 are not snap targets', () async {
    final c = await _ctrl();
    c.scaleMonitor('A', 4.01, committing: true);
    expect(c.activeMonitors.first.scale, equals(4.01));
  });
}
