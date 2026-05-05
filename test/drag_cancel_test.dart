import 'dart:io';

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

ConfigService _tmpConfig(Directory dir) => ConfigService(
      configPath: '${dir.path}/c',
      backupPrefix: '${dir.path}/c.bak',
      writeOptions: KanshiWriteOptions.neutral,
    );

Future<KanshiController> _twoMonitorCtrl(Directory dir) async {
  final fake = FakeMonitorService(
    outputs: [_mon(id: 'A'), _mon(id: 'B', x: 1920)],
  );
  final c = KanshiController(monitors: fake, config: _tmpConfig(dir));
  await c.init();
  if (c.profiles.isEmpty) c.createProfileFromCurrentSetup();
  c.setActiveProfile(0);
  return c;
}

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('kanshi_gui_drag_cancel_');
  });
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('drag cancel epoch', () {
    test('starts at zero and is returned by beginDragSession', () async {
      final c = await _twoMonitorCtrl(tmp);
      expect(c.dragCancelEpoch, 0);
      final epoch = c.beginDragSession('B', _mon(id: 'B', x: 1920));
      expect(epoch, 0);
      expect(c.dragCancelEpoch, 0,
          reason: 'Starting a drag must not bump the cancel epoch.');
      c.endDragSession('B');
    });

    test('clean drag → endDragSession leaves the epoch untouched', () async {
      final c = await _twoMonitorCtrl(tmp);
      final epoch = c.beginDragSession('B', _mon(id: 'B', x: 1920));
      c.updateMonitor(_mon(id: 'B', x: 2000));
      c.endDragSession('B');
      expect(c.dragCancelEpoch, equals(epoch));
    });

    test('hotplug-disconnect during a drag bumps the cancel epoch', () async {
      final c = await _twoMonitorCtrl(tmp);
      final fake = c.monitors as FakeMonitorService;
      final epoch = c.beginDragSession('B', _mon(id: 'B', x: 1920));
      c.updateMonitor(_mon(id: 'B', x: 9000));
      // Simulate yanking monitor A while dragging B.
      fake.emitOutputs([_mon(id: 'B', x: 1920)]);
      // The hotplug listener runs as part of the broadcast stream loop;
      // give the microtask queue a chance to drain.
      await Future<void>.delayed(Duration.zero);
      expect(c.dragCancelEpoch, greaterThan(epoch),
          reason: 'A hotplug event during a drag must invalidate the gesture.');
    });

    test('cancellation rolls the dragged tile back to its pre-drag state',
        () async {
      final c = await _twoMonitorCtrl(tmp);
      final fake = c.monitors as FakeMonitorService;
      final originalB = c.activeMonitors.firstWhere((m) => m.id == 'B');
      c.beginDragSession('B', originalB);
      // Drag B way off to the right…
      c.updateMonitor(originalB.copyWith(x: 9999));
      final movedB = c.activeMonitors.firstWhere((m) => m.id == 'B');
      expect(movedB.x, equals(9999),
          reason: 'Sanity: mid-drag updates write into the profile.');
      // …then yank A.
      fake.emitOutputs([_mon(id: 'B', x: 1920)]);
      await Future<void>.delayed(Duration.zero);
      // The active profile's B-tile should be back at its pre-drag x.
      final restoredB = c.activeMonitors.firstWhere((m) => m.id == 'B');
      expect(restoredB.x, equals(originalB.x),
          reason: 'Cancellation must restore the rollback snapshot.');
    });

    test('profile switch mid-drag also bumps the cancel epoch', () async {
      final c = await _twoMonitorCtrl(tmp);
      // Make sure there's a second profile to switch into.
      c.createProfileFromCurrentSetup();
      final epoch = c.beginDragSession('B', _mon(id: 'B', x: 1920));
      c.setActiveProfile(c.profiles.length - 1);
      expect(c.dragCancelEpoch, greaterThan(epoch));
    });

    test('hotplug without an active drag does not bump the epoch', () async {
      final c = await _twoMonitorCtrl(tmp);
      final fake = c.monitors as FakeMonitorService;
      final epoch = c.dragCancelEpoch;
      // Disconnect+reconnect with no drag in flight — epoch must stay put,
      // otherwise every cable jiggle would burn a token for no reason.
      fake.emitOutputs([_mon(id: 'A')]);
      await Future<void>.delayed(Duration.zero);
      expect(c.dragCancelEpoch, equals(epoch));
    });
  });
}
