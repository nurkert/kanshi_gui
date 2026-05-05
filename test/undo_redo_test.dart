import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kanshi_gui/models/monitor_tile_data.dart';
import 'package:kanshi_gui/services/config_service.dart';
import 'package:kanshi_gui/services/kanshi_config_writer.dart';
import 'package:kanshi_gui/state/kanshi_controller.dart';

import 'fakes/fake_monitor_service.dart';

MonitorTileData _mon({
  required String id,
  double x = 0,
  double y = 0,
  bool enabled = true,
}) =>
    MonitorTileData(
      id: id,
      manufacturer: id,
      x: x,
      y: y,
      width: 1920,
      height: 1080,
      scale: 1.0,
      rotation: 0,
      refresh: 60,
      resolution: '1920x1080',
      orientation: 'landscape',
      enabled: enabled,
    );

ConfigService _tmpConfig(Directory d) => ConfigService(
      configPath: '${d.path}/c',
      backupPrefix: '${d.path}/c.bak',
      writeOptions: KanshiWriteOptions.neutral,
    );

Future<KanshiController> _twoMonitorCtrl(Directory dir) async {
  final cfg = _tmpConfig(dir);
  final fake = FakeMonitorService(
    outputs: [_mon(id: 'A'), _mon(id: 'B', x: 1920)],
  );
  final c = KanshiController(monitors: fake, config: cfg);
  await c.init();
  return c;
}

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('kanshi_gui_undo_');
  });
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('undo/redo basics', () {
    test('canUndo / canRedo start out false', () async {
      final c = await _twoMonitorCtrl(tmp);
      expect(c.canUndo, isFalse);
      expect(c.canRedo, isFalse);
      expect(c.nextUndoLabel, isNull);
      expect(c.nextRedoLabel, isNull);
    });

    test('snapAndCommit pushes a "move <id>" undoable step', () async {
      final c = await _twoMonitorCtrl(tmp);
      final originalB = c.activeMonitors.firstWhere((m) => m.id == 'B');
      c.beginDragSession('B', originalB);
      // Simulate a mid-drag write followed by a commit.
      c.updateMonitor(originalB.copyWith(x: 4000));
      c.snapAndCommit(originalB.copyWith(x: 4000), originalB);
      c.endDragSession('B');
      expect(c.canUndo, isTrue);
      expect(c.nextUndoLabel, 'move B');
    });

    test('undo restores the pre-drag position from the rollback', () async {
      final c = await _twoMonitorCtrl(tmp);
      final originalB = c.activeMonitors.firstWhere((m) => m.id == 'B');
      c.beginDragSession('B', originalB);
      c.updateMonitor(originalB.copyWith(x: 4000));
      c.snapAndCommit(originalB.copyWith(x: 4000), originalB);
      c.endDragSession('B');
      final after = c.activeMonitors.firstWhere((m) => m.id == 'B');
      expect(after.x, equals(4000),
          reason: 'commit landed at 4000 (no overlap snap target).');
      final r = await c.undo();
      expect(r.success, isTrue);
      final undone = c.activeMonitors.firstWhere((m) => m.id == 'B');
      expect(undone.x, equals(originalB.x),
          reason: 'Undo must restore the pre-drag rollback position.');
    });

    test('redo replays the change after an undo', () async {
      final c = await _twoMonitorCtrl(tmp);
      final originalB = c.activeMonitors.firstWhere((m) => m.id == 'B');
      c.beginDragSession('B', originalB);
      c.updateMonitor(originalB.copyWith(x: 4000));
      c.snapAndCommit(originalB.copyWith(x: 4000), originalB);
      c.endDragSession('B');
      await c.undo();
      expect(c.canRedo, isTrue);
      final r = await c.redo();
      expect(r.success, isTrue);
      final redone = c.activeMonitors.firstWhere((m) => m.id == 'B');
      expect(redone.x, equals(4000));
    });

    test('toggleEnabled is undoable', () async {
      final c = await _twoMonitorCtrl(tmp);
      // Pre-condition: B is enabled.
      expect(c.activeMonitors.firstWhere((m) => m.id == 'B').enabled, isTrue);
      final r = await c.toggleEnabled('B', false);
      expect(r.success, isTrue);
      expect(c.activeMonitors.firstWhere((m) => m.id == 'B').enabled, isFalse);
      await c.undo();
      expect(c.activeMonitors.firstWhere((m) => m.id == 'B').enabled, isTrue,
          reason: 'Undo of disable should re-enable B.');
    });

    test('renameProfile is undoable', () async {
      final c = await _twoMonitorCtrl(tmp);
      final r = c.renameProfile(0, 'NewName');
      expect(r.success, isTrue);
      expect(c.profiles.first.name, 'NewName');
      await c.undo();
      expect(c.profiles.first.name, isNot('NewName'));
    });

    test('a fresh mutation after undo clears the redo stack', () async {
      final c = await _twoMonitorCtrl(tmp);
      final originalB = c.activeMonitors.firstWhere((m) => m.id == 'B');
      c.beginDragSession('B', originalB);
      c.updateMonitor(originalB.copyWith(x: 4000));
      c.snapAndCommit(originalB.copyWith(x: 4000), originalB);
      c.endDragSession('B');
      await c.undo();
      expect(c.canRedo, isTrue);
      // Different mutation: rename the profile.
      c.renameProfile(0, 'Other');
      expect(c.canRedo, isFalse,
          reason: 'New mutation must invalidate the redo path.');
    });

    test('undo on an empty stack returns an error result', () async {
      final c = await _twoMonitorCtrl(tmp);
      final r = await c.undo();
      expect(r.success, isFalse);
      expect(r.message, contains('Nothing to undo'));
    });

    test('history is capped at 30 entries', () async {
      final c = await _twoMonitorCtrl(tmp);
      // Drive 35 toggle cycles → only the last 30 should remain.
      for (var i = 0; i < 35; i++) {
        await c.toggleEnabled('B', i.isEven ? false : true);
      }
      // Walk all the way back via undo and assert we only get 30 hits.
      var undos = 0;
      while ((await c.undo()).success) {
        undos++;
        if (undos > 100) break;
      }
      expect(undos, equals(30),
          reason: 'Undo stack must not grow unbounded.');
    });
  });

  group('drag cancel and undo coexist', () {
    test('a cancelled drag does not leave a stray history entry', () async {
      final c = await _twoMonitorCtrl(tmp);
      final fake = c.monitors as FakeMonitorService;
      final originalB = c.activeMonitors.firstWhere((m) => m.id == 'B');
      c.beginDragSession('B', originalB);
      c.updateMonitor(originalB.copyWith(x: 4000));
      // Hotplug invalidates the drag — `_cancelInFlightDrags` rolls
      // back the tile and should NOT leave a history entry behind
      // (since beginDragSession itself doesn't push, and snapAndCommit
      // never runs on cancellation).
      fake.emitOutputs([_mon(id: 'A')]);
      await pumpEventQueue();
      expect(c.canUndo, isFalse,
          reason: 'A cancelled drag should not produce an undoable entry.');
    });
  });
}
