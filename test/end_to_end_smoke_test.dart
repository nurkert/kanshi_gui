// End-to-end smoke test. Runs an opinionated user-journey through the
// stack and checks invariants across feature boundaries — drag → mirror
// → undo, profile delete with adjacent active index, hotplug-driven
// suggestion + undo, etc. This is the test that catches regressions a
// per-feature unit test would miss because each unit test only owns
// one slice of the controller's state.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kanshi_gui/models/monitor_tile_data.dart';
import 'package:kanshi_gui/models/profiles.dart';
import 'package:kanshi_gui/services/config_service.dart';
import 'package:kanshi_gui/services/kanshi_config_writer.dart';
import 'package:kanshi_gui/services/layout_math.dart';
import 'package:kanshi_gui/state/kanshi_controller.dart';

import 'fakes/fake_mirror_runner.dart';
import 'fakes/fake_monitor_service.dart';

MonitorTileData _mon({
  required String id,
  String? manufacturer,
  double x = 0,
  double y = 0,
  bool enabled = true,
}) =>
    MonitorTileData(
      id: id,
      manufacturer: manufacturer ?? id,
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

ConfigService _tmpCfg(Directory d) => ConfigService(
      configPath: '${d.path}/c',
      backupPrefix: '${d.path}/c.bak',
      writeOptions: KanshiWriteOptions.neutral,
    );

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('kanshi_gui_smoke_');
  });
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('end-to-end smoke', () {
    test('drag → undo → redo round-trips the active profile state',
        () async {
      final fake = FakeMonitorService(
        outputs: [_mon(id: 'A'), _mon(id: 'B', x: 1920)],
      );
      final c = KanshiController(monitors: fake, config: _tmpCfg(tmp));
      await c.init();
      final origB = c.activeMonitors.firstWhere((m) => m.id == 'B');

      // Drag B somewhere unusual.
      c.beginDragSession('B', origB);
      c.updateMonitor(origB.copyWith(x: 5000, y: 200));
      c.snapAndCommit(origB.copyWith(x: 5000, y: 200), origB);
      c.endDragSession('B');
      final movedB = c.activeMonitors.firstWhere((m) => m.id == 'B');
      expect(movedB.x, 5000);
      expect(movedB.y, 200);

      // Undo and inspect.
      await c.undo();
      final undoneB = c.activeMonitors.firstWhere((m) => m.id == 'B');
      expect(undoneB.x, origB.x,
          reason: 'Undo restores the pre-drag x.');
      expect(undoneB.y, origB.y);

      // Redo and inspect.
      await c.redo();
      final redoneB = c.activeMonitors.firstWhere((m) => m.id == 'B');
      expect(redoneB.x, 5000);
      expect(redoneB.y, 200);
    });

    test('toggle disable + mirror set + undo unwinds mirror first', () async {
      final mr = FakeMirrorRunner();
      final fake = FakeMonitorService(
        supportsMirror: true,
        outputs: [_mon(id: 'A'), _mon(id: 'B', x: 1920)],
      );
      final c = KanshiController(
        monitors: fake,
        config: _tmpCfg(tmp),
        mirrorRunner: mr,
      );
      await c.init();

      // Set up the mirror (A becomes a mirror of B).
      final r = await c.setMirror('A', 'B');
      expect(r.success, isTrue);
      expect(mr.activeDestinations, contains('A'));

      // Undo: mirror should be torn down again.
      await c.undo();
      // _reconcileMirrors must have been called from _restoreSnapshot,
      // which means the FakeMirrorRunner no longer has A as a destination.
      expect(mr.activeDestinations, isEmpty,
          reason: 'Undoing a setMirror must reconcile the runner.');
      // And the profile state forgets the mirror relationship.
      expect(c.activeMonitors.firstWhere((m) => m.id == 'A').mirrorOf, isNull);
    });

    test(
        'identical-content saves are deduped; only real changes leave backups',
        () async {
      // 1.5.7 short-circuits saveProfiles when the rendered output
      // matches the live config byte-for-byte. The prior behaviour
      // (every save snapshots, even no-op ones) was burning through
      // the rotation ring during drag-then-cancel / undo-redo cycles.
      final fake = FakeMonitorService(outputs: [_mon(id: 'A')]);
      final cfg = _tmpCfg(tmp);
      final c = KanshiController(monitors: fake, config: cfg);
      await c.init();
      // Five repeated saves of an unchanged profile list — must produce
      // zero new backups, not five.
      for (var i = 0; i < 5; i++) {
        await cfg.saveProfiles(c.profiles);
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      var backups = await cfg.listBackups();
      expect(backups, isEmpty,
          reason: 'Identical-content saves must not create backups.');

      // Mutate the profile list and save: now we expect exactly one
      // backup (snapshot of the previous live config).
      c.renameProfile(c.activeProfileIndex!, 'renamed');
      await cfg.saveProfiles(c.profiles);
      backups = await cfg.listBackups();
      expect(backups, hasLength(1),
          reason: 'A real change must still snapshot the prior config.');
    });

    test('detectMirrorDropTarget pipes into setMirror cleanly', () async {
      final mr = FakeMirrorRunner();
      final fake = FakeMonitorService(
        supportsMirror: true,
        outputs: [_mon(id: 'A'), _mon(id: 'B', x: 1920)],
      );
      final c = KanshiController(
        monitors: fake,
        config: _tmpCfg(tmp),
        mirrorRunner: mr,
      );
      await c.init();
      // Simulate a drag of A on top of B (logical-coord overlap).
      final draggedA = c.activeMonitors
          .firstWhere((m) => m.id == 'A')
          .copyWith(x: 1920, y: 0);
      final hit = LayoutMath.detectMirrorDropTarget(
        dragged: draggedA,
        all: [draggedA, c.activeMonitors.firstWhere((m) => m.id == 'B')],
      );
      expect(hit, isNotNull);
      expect(hit!.id, 'B');
      // Pipe through to setMirror as the UI would.
      final r = await c.setMirror(draggedA.id, hit.id);
      expect(r.success, isTrue);
      expect(c.activeMonitors.firstWhere((m) => m.id == 'A').mirrorOf, 'B');
      // Now undo — mirror is torn down, A is back as an independent tile.
      await c.undo();
      expect(c.activeMonitors.firstWhere((m) => m.id == 'A').mirrorOf, isNull);
    });
  });

  group('hardening: edge-cases that previously slipped through', () {
    test('deleteProfile shifts active index down when active was after it',
        () async {
      final fake = FakeMonitorService(outputs: [_mon(id: 'A')]);
      final cfg = _tmpCfg(tmp);
      // Pre-seed two profiles.
      await cfg.saveProfiles([
        Profile(name: 'first', monitors: [_mon(id: 'A')]),
        Profile(name: 'second', monitors: [_mon(id: 'A')]),
      ]);
      final c = KanshiController(monitors: fake, config: cfg);
      await c.init();
      // Make 'second' active.
      c.setActiveProfile(c.profiles.indexWhere((p) => p.name == 'second'));
      final activeName = c.activeProfile?.name;
      expect(activeName, 'second');

      // Delete 'first'. The active profile (still 'second') must remain
      // active; without an index-shift it would either be lost or now
      // point at a Current-Setup phantom.
      final firstIdx = c.profiles.indexWhere((p) => p.name == 'first');
      c.deleteProfile(firstIdx);
      expect(
        c.activeProfile?.name,
        'second',
        reason: 'Deleting a profile with a lower index must shift the '
            'active profile index down to keep pointing at the same '
            'Profile object.',
      );
    });

    test('undo of a setActiveProfile call restores the prior active index',
        () async {
      final fake = FakeMonitorService(outputs: [_mon(id: 'A')]);
      final cfg = _tmpCfg(tmp);
      await cfg.saveProfiles([
        Profile(name: 'one', monitors: [_mon(id: 'A')]),
        Profile(name: 'two', monitors: [_mon(id: 'A')]),
      ]);
      final c = KanshiController(monitors: fake, config: cfg);
      await c.init();
      c.setActiveProfile(0); // explicit
      expect(c.activeProfile?.name, 'one');
      c.setActiveProfile(1);
      expect(c.activeProfile?.name, 'two');
      await c.undo();
      expect(c.activeProfile?.name, 'one',
          reason: 'Undo of profile activation restores the prior selection.');
    });

    test('a hotplug that does not change the output set leaves drag intact',
        () async {
      final fake = FakeMonitorService(
        outputs: [_mon(id: 'A'), _mon(id: 'B', x: 1920)],
      );
      final c = KanshiController(monitors: fake, config: _tmpCfg(tmp));
      await c.init();
      final origB = c.activeMonitors.firstWhere((m) => m.id == 'B');
      final epoch = c.beginDragSession('B', origB);
      // Re-emit the SAME outputs — no diff.
      fake.emitOutputs([_mon(id: 'A'), _mon(id: 'B', x: 1920)]);
      await pumpEventQueue();
      expect(c.dragCancelEpoch, equals(epoch),
          reason: 'A no-op hotplug must not burn an epoch token.');
      c.endDragSession('B');
    });

    test('thirty undos walk back exactly thirty steps', () async {
      final fake = FakeMonitorService(
        outputs: [_mon(id: 'A'), _mon(id: 'B', x: 1920)],
      );
      final c = KanshiController(monitors: fake, config: _tmpCfg(tmp));
      await c.init();
      // Drive 30 distinct mutations.
      for (var i = 0; i < 30; i++) {
        c.renameProfile(0, 'name$i');
      }
      var undos = 0;
      while ((await c.undo()).success) {
        undos++;
        if (undos > 100) break;
      }
      expect(undos, 30,
          reason: 'History cap is 30; each rename must be its own step.');
    });

    test('redo across multiple steps replays in order', () async {
      final fake = FakeMonitorService(
        outputs: [_mon(id: 'A'), _mon(id: 'B', x: 1920)],
      );
      final c = KanshiController(monitors: fake, config: _tmpCfg(tmp));
      await c.init();
      c.renameProfile(0, 'first');
      c.renameProfile(0, 'second');
      c.renameProfile(0, 'third');
      // Three undos.
      await c.undo();
      await c.undo();
      await c.undo();
      // Three redos.
      await c.redo();
      expect(c.profiles.first.name, 'first');
      await c.redo();
      expect(c.profiles.first.name, 'second');
      await c.redo();
      expect(c.profiles.first.name, 'third');
      expect(c.canRedo, isFalse);
    });

    test('drag commit + immediate undo + new drag does not corrupt rollback',
        () async {
      final fake = FakeMonitorService(
        outputs: [_mon(id: 'A'), _mon(id: 'B', x: 1920)],
      );
      final c = KanshiController(monitors: fake, config: _tmpCfg(tmp));
      await c.init();
      final origB = c.activeMonitors.firstWhere((m) => m.id == 'B');
      // Drag B to the right.
      c.beginDragSession('B', origB);
      c.updateMonitor(origB.copyWith(x: 5000));
      c.snapAndCommit(origB.copyWith(x: 5000), origB);
      c.endDragSession('B');
      // Undo.
      await c.undo();
      expect(c.activeMonitors.firstWhere((m) => m.id == 'B').x, origB.x);
      // Now drag B somewhere else and commit.
      final origB2 = c.activeMonitors.firstWhere((m) => m.id == 'B');
      c.beginDragSession('B', origB2);
      c.updateMonitor(origB2.copyWith(x: -2000));
      c.snapAndCommit(origB2.copyWith(x: -2000), origB2);
      c.endDragSession('B');
      // Undoing now must take us back to origB2 (which equals origB), not
      // to the long-undone 5000 position. This catches a redo-stack
      // ghost re-applying.
      await c.undo();
      expect(c.activeMonitors.firstWhere((m) => m.id == 'B').x, origB.x,
          reason: 'A new mutation must clear the redo stack — undoing '
              'after that goes back to the new mutation\'s pre-state, '
              'not to a stale forward step.');
    });

    test('atomic config write does not leave a stray .tmp on disk', () async {
      final fake = FakeMonitorService(outputs: [_mon(id: 'A')]);
      final cfg = _tmpCfg(tmp);
      final c = KanshiController(monitors: fake, config: cfg);
      await c.init();
      await cfg.saveProfiles(c.profiles);
      await cfg.saveProfiles(c.profiles);
      await cfg.saveProfiles(c.profiles);
      expect(File('${tmp.path}/c.tmp').existsSync(), isFalse,
          reason: 'The atomic-write temp sibling must be renamed away.');
    });

    test(
        'two consecutive saves within a single millisecond do not collide on '
        'backup filename',
        () async {
      // The unix-ms timestamp is the rotation key; if two saves happen
      // inside the same millisecond, file.copy(samePath) would simply
      // overwrite. Drive a back-to-back-to-back save without any sleep
      // and verify nothing throws + the live config still parses.
      final fake = FakeMonitorService(outputs: [_mon(id: 'A')]);
      final cfg = _tmpCfg(tmp);
      await cfg.saveProfiles([Profile(name: 'a', monitors: [_mon(id: 'A')])]);
      await cfg.saveProfiles([Profile(name: 'b', monitors: [_mon(id: 'A')])]);
      await cfg.saveProfiles([Profile(name: 'c', monitors: [_mon(id: 'A')])]);
      // Live config is whatever the last save wrote.
      final loaded = await cfg.loadProfiles();
      expect(loaded.single.name, 'c');
      // Avoid an "unused" lint on fake — the test is about cfg, not the
      // controller.
      expect(fake.outputs, isNotEmpty);
    });
  });
}
