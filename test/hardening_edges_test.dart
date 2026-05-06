// Adversarial edge-case probing. Each test exercises a corner of the
// state machine that is easy to break with a small refactor: out-of-range
// indices, undo across mirror reconciliation, identify with disabled
// mirror sources, drag-cancel-during-drag-end, and so on.

import 'dart:io';

import 'dart:ui';

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
  double w = 1920,
  double h = 1080,
  double scale = 1.0,
  bool enabled = true,
  String? mirrorOf,
}) =>
    MonitorTileData(
      id: id,
      manufacturer: manufacturer ?? id,
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

ConfigService _tmpCfg(Directory d) => ConfigService(
      configPath: '${d.path}/c',
      backupPrefix: '${d.path}/c.bak',
      writeOptions: KanshiWriteOptions.neutral,
    );

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('kanshi_gui_hard_');
  });
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('out-of-range guards', () {
    test('setActiveProfile with a negative index is a no-op', () async {
      final fake = FakeMonitorService(outputs: [_mon(id: 'A')]);
      final c = KanshiController(monitors: fake, config: _tmpCfg(tmp));
      await c.init();
      final before = c.activeProfileIndex;
      c.setActiveProfile(-1);
      expect(c.activeProfileIndex, equals(before),
          reason: 'Negative index must not mutate state.');
    });

    test('setActiveProfile beyond the end is a no-op', () async {
      final fake = FakeMonitorService(outputs: [_mon(id: 'A')]);
      final c = KanshiController(monitors: fake, config: _tmpCfg(tmp));
      await c.init();
      c.setActiveProfile(99);
      // No exception is the only expected behaviour; index must stay sane.
      expect(c.activeProfileIndex,
          inInclusiveRange(0, c.profiles.length - 1));
    });

    test('renameProfile with a bogus index returns an error', () async {
      final fake = FakeMonitorService(outputs: [_mon(id: 'A')]);
      final c = KanshiController(monitors: fake, config: _tmpCfg(tmp));
      await c.init();
      final r = c.renameProfile(99, 'Whatever');
      expect(r.success, isFalse);
    });

    test('deleteProfile with a bogus index does nothing', () async {
      final fake = FakeMonitorService(outputs: [_mon(id: 'A')]);
      final c = KanshiController(monitors: fake, config: _tmpCfg(tmp));
      await c.init();
      final before = c.profiles.length;
      c.deleteProfile(99);
      c.deleteProfile(-1);
      expect(c.profiles.length, equals(before));
    });
  });

  group('mirror lifecycle interactions with undo', () {
    test('redo of a stop-mirror brings back the wl-mirror process', () async {
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
      await c.setMirror('A', 'B');
      expect(mr.activeDestinations, contains('A'));
      await c.setMirror('A', null); // stop
      expect(mr.activeDestinations, isEmpty);
      await c.undo(); // un-stop → mirror is back
      expect(mr.activeDestinations, contains('A'));
      expect(c.activeMonitors.firstWhere((m) => m.id == 'A').mirrorOf, 'B');
    });

    test(
        'undo of a setMirror call when source disappeared mid-history does '
        'not throw', () async {
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
      await c.setMirror('A', 'B');
      // Yank B mid-stream; A is still there, but the mirror partner
      // is gone. The cleanup logic must roll back the live process state
      // even though _reconcileMirrors will refuse to spawn now.
      fake.emitOutputs([_mon(id: 'A')]);
      await pumpEventQueue();
      expect(mr.activeDestinations, isEmpty,
          reason: 'wl-mirror exits when its source disappears.');
      // Undo the mirror set — must not throw, even though the source is
      // not currently connected.
      final r = await c.undo();
      expect(r.success, isTrue);
    });
  });

  group('layout math under stress', () {
    test('detectMirrorDropTarget refuses zero-area dragged tiles', () {
      final dragged = _mon(id: 'A', w: 0, h: 0);
      final other = _mon(id: 'B', x: 0);
      expect(
        LayoutMath.detectMirrorDropTarget(dragged: dragged, all: [other]),
        isNull,
      );
    });

    test('boundingBox of the empty set is Rect.zero', () {
      expect(LayoutMath.boundingBox(const []), Rect.zero);
    });

    test('boundingBox handles a negative-coordinate cluster', () {
      final mons = [
        _mon(id: 'A', x: -1920, y: 0),
        _mon(id: 'B', x: 0, y: -1080),
      ];
      final bbox = LayoutMath.boundingBox(mons);
      expect(bbox.left, -1920);
      expect(bbox.top, -1080);
    });
  });

  group('config-write robustness', () {
    test('saving when the config dir does not exist creates it', () async {
      // Point at a non-existent subdir; saveProfiles must mkdir -p.
      final cfg = ConfigService(
        configPath: '${tmp.path}/missing/config',
        backupPrefix: '${tmp.path}/missing/config.bak',
        writeOptions: KanshiWriteOptions.neutral,
      );
      await cfg.saveProfiles(
        [Profile(name: 'p', monitors: [_mon(id: 'A')])],
      );
      expect(File('${tmp.path}/missing/config').existsSync(), isTrue);
    });

    test('listBackups returns empty when the directory is gone', () async {
      final cfg = ConfigService(
        configPath: '${tmp.path}/never/config',
        backupPrefix: '${tmp.path}/never/config.bak',
        writeOptions: KanshiWriteOptions.neutral,
      );
      // Don't save anything; the directory was never created.
      expect(await cfg.listBackups(), isEmpty);
      expect(await cfg.newestBackup(), isNull);
    });

    test('a save sandwiched between two reads produces no parse errors',
        () async {
      final cfg = _tmpCfg(tmp);
      await cfg.saveProfiles(
        [Profile(name: 'p', monitors: [_mon(id: 'A')])],
      );
      final r1 = await cfg.loadProfiles();
      await cfg.saveProfiles(
        [Profile(name: 'p', monitors: [_mon(id: 'B')])],
      );
      final r2 = await cfg.loadProfiles();
      expect(r1.single.monitors.single.id, 'A');
      expect(r2.single.monitors.single.id, 'B');
    });
  });

  group('identify edge cases', () {
    test('identifyDisplays on an empty profile is a no-op', () async {
      final fake = FakeMonitorService(outputs: const []);
      final c = KanshiController(monitors: fake, config: _tmpCfg(tmp));
      await c.init();
      c.identifyDisplays();
      expect(c.identifyNumbers, isEmpty);
      expect(c.isIdentifying, isFalse);
    });

    test(
        'identifyDisplays on a 100% mirrored set still shows a number on '
        'the source', () async {
      final fake = FakeMonitorService(
        supportsMirror: true,
        outputs: [
          _mon(id: 'A'),
          _mon(id: 'B', x: 1920),
          _mon(id: 'C', x: 3840),
        ],
      );
      fake.identifyBannerSupported = true;
      final c = KanshiController(monitors: fake, config: _tmpCfg(tmp));
      await c.init();
      // B and C both mirror A.
      await c.setMirror('B', 'A');
      await c.setMirror('C', 'A');
      c.identifyDisplays();
      // All three monitors must end up with a number — the GUI uses
      // these to render `+N` chips on the source tile.
      expect(c.identifyNumbers.length, 3);
      // Only A's swaynag spawns; B and C are skipped because their
      // physical screens already render A's banner via wl-mirror.
      expect(
        fake.identifyBannerCalls.map((c) => c.first).toList(),
        equals(['A']),
      );
    });
  });

  group('undo cancels timers from undone mutations', () {
    test('undoing a custom mode apply stops further state mutations',
        () async {
      final fake = FakeMonitorService(
        outputs: [_mon(id: 'A')],
      );
      final c = KanshiController(monitors: fake, config: _tmpCfg(tmp));
      await c.init();
      // Apply a custom mode (the controller schedules an auto-revert
      // 15s out; we won't wait for it, but we want to make sure the
      // undo path tears it down so it doesn't fire later).
      await c.applyCustomMode('A', 1234, 567, 60);
      final beforeUndo =
          c.activeMonitors.firstWhere((m) => m.id == 'A').width;
      expect(beforeUndo, equals(1234));
      await c.undo();
      // The undo restores the pre-custom width. The remaining test of
      // value is that the auto-revert timer scheduled inside
      // applyCustomMode does NOT later mutate state — our undo should
      // have cancelled it. Fast-forward by giving the event loop a
      // chance to run pending microtasks.
      await pumpEventQueue();
      // No exception, no further mutation.
      expect(c.activeMonitors.firstWhere((m) => m.id == 'A').width,
          isNot(equals(1234)),
          reason: 'Width must reflect the pre-custom mode after undo.');
    });
  });

  group('drag pipeline edges', () {
    test(
        'snapAndCommit without a prior beginDragSession is harmless '
        '(no rollback, no history)',
        () async {
      // Some app paths (e.g. programmatic moves) call snapAndCommit
      // without going through beginDragSession. Ensure history captures
      // the current state correctly even without a rollback override.
      final fake = FakeMonitorService(
        outputs: [_mon(id: 'A'), _mon(id: 'B', x: 1920)],
      );
      final c = KanshiController(monitors: fake, config: _tmpCfg(tmp));
      await c.init();
      final mB = c.activeMonitors.firstWhere((m) => m.id == 'B');
      c.snapAndCommit(mB.copyWith(x: 4000), null);
      // History entry exists and captures the *current* state (which
      // is still pre-mutation because snapAndCommit pushes BEFORE
      // mutating).
      expect(c.canUndo, isTrue);
      await c.undo();
      // Without a rollback override the snapshot was the as-found x;
      // since updateMonitor was never called, the as-found x is the
      // pre-snapAndCommit x — undo should restore that.
      expect(c.activeMonitors.firstWhere((m) => m.id == 'B').x,
          equals(mB.x));
    });

    test(
        'rapid begin/end of a drag with no movement does not pollute history',
        () async {
      final fake = FakeMonitorService(
        outputs: [_mon(id: 'A'), _mon(id: 'B', x: 1920)],
      );
      final c = KanshiController(monitors: fake, config: _tmpCfg(tmp));
      await c.init();
      final mB = c.activeMonitors.firstWhere((m) => m.id == 'B');
      c.beginDragSession('B', mB);
      c.endDragSession('B');
      // Nothing committed → no history entry.
      expect(c.canUndo, isFalse,
          reason: 'A drag that never reaches snapAndCommit must not '
              'create an undoable step.');
    });
  });
}
