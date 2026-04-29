import 'package:flutter_test/flutter_test.dart';
import 'package:kanshi_gui/models/monitor_tile_data.dart';
import 'package:kanshi_gui/services/config_service.dart';
import 'package:kanshi_gui/services/kanshi_config_writer.dart';
import 'package:kanshi_gui/state/kanshi_controller.dart';

import 'fakes/fake_monitor_service.dart';

MonitorTileData _mon({
  String id = 'M',
  double x = 0,
  double y = 0,
  double w = 1920,
  double h = 1080,
}) =>
    MonitorTileData(
      id: id,
      manufacturer: id,
      x: x,
      y: y,
      width: w,
      height: h,
      scale: 1.0,
      rotation: 0,
      refresh: 60,
      resolution: '${w.toInt()}x${h.toInt()}',
      orientation: 'landscape',
    );

ConfigService _tmpConfig(String dir) => ConfigService(
      configPath: '$dir/c',
      backupPath: '$dir/c.bak',
      writeOptions: KanshiWriteOptions.neutral,
    );

Future<KanshiController> _twoMonitorCtrl(String dir) async {
  final cfg = _tmpConfig(dir);
  final fake = FakeMonitorService(outputs: [_mon(id: 'A')]);
  final c = KanshiController(monitors: fake, config: cfg);
  await c.init();
  // Replace the active profile with a known A+B layout.
  c.deleteProfile(0);
  c.profiles; // touch
  // Use createProfileFromCurrentSetup with two monitors to seed.
  fake.outputs = [_mon(id: 'A'), _mon(id: 'B', x: 1920, y: 0)];
  await c.refreshConnectedMonitors();
  c.createProfileFromCurrentSetup();
  return c;
}

void main() {
  /// Simulates one drag frame: the UI calls updateMonitor (writing the
  /// raw drag position into the profile) and then previewSnap.
  void drag(KanshiController c, MonitorTileData m) {
    c.updateMonitor(m);
    c.previewSnap(m);
  }

  test('alignment magnet still active on the first drag of a session',
      () async {
    final c = await _twoMonitorCtrl('/tmp');
    c.beginDragSession('B');
    drag(c, _mon(id: 'B', x: 1925, y: 8));
    c.snapAndCommit(_mon(id: 'B', x: 1925, y: 8), null);
    final b1 = c.activeMonitors.firstWhere((m) => m.id == 'B');
    expect(b1.x, equals(1920));
    expect(b1.y, equals(0));
    c.endDragSession('B');
  });

  test(
      'two escapes within one drag session disables Y-alignment for the '
      'rest of that drag', () async {
    final c = await _twoMonitorCtrl('/tmp');
    c.beginDragSession('B');
    drag(c, _mon(id: 'B', x: 1925, y: 8));   // align (lastY=true)
    drag(c, _mon(id: 'B', x: 1925, y: 600)); // escape #1
    drag(c, _mon(id: 'B', x: 1925, y: 8));   // align again (lastY=true)
    drag(c, _mon(id: 'B', x: 1925, y: 600)); // escape #2
    drag(c, _mon(id: 'B', x: 1925, y: 12));  // alignment suppressed
    c.snapAndCommit(_mon(id: 'B', x: 1925, y: 12), null);
    final b = c.activeMonitors.firstWhere((m) => m.id == 'B');
    expect(b.x, equals(1920)); // edge snap still wins
    expect(b.y, equals(12));    // alignment suppressed
    c.endDragSession('B');
  });

  test('endDragSession + beginDragSession resets escape memory', () async {
    final c = await _twoMonitorCtrl('/tmp');
    c.beginDragSession('B');
    drag(c, _mon(id: 'B', x: 1925, y: 8));
    drag(c, _mon(id: 'B', x: 1925, y: 600));
    drag(c, _mon(id: 'B', x: 1925, y: 8));
    drag(c, _mon(id: 'B', x: 1925, y: 600));
    c.endDragSession('B');
    // Fresh grab → alignment magnet active again.
    c.beginDragSession('B');
    drag(c, _mon(id: 'B', x: 1925, y: 8));
    c.snapAndCommit(_mon(id: 'B', x: 1925, y: 8), null);
    final b = c.activeMonitors.firstWhere((m) => m.id == 'B');
    expect(b.y, equals(0));
    c.endDragSession('B');
  });
}
