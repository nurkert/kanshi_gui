import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kanshi_gui/models/monitor_tile_data.dart';
import 'package:kanshi_gui/models/profiles.dart';
import 'package:kanshi_gui/services/config_service.dart';
import 'package:kanshi_gui/services/kanshi_config_parser.dart';
import 'package:kanshi_gui/services/kanshi_config_writer.dart';
import 'package:kanshi_gui/state/kanshi_controller.dart';

import 'fakes/fake_mirror_runner.dart';
import 'fakes/fake_monitor_service.dart';

/// M4 — an operation may not report success it did not achieve.
MonitorTileData _mon({
  required String id,
  double x = 0,
  double y = 0,
  double w = 1920,
  double h = 1080,
  bool enabled = true,
}) =>
    MonitorTileData(
      id: id,
      manufacturer: id,
      x: x,
      y: y,
      width: w,
      height: h,
      rotation: 0,
      refresh: 60,
      resolution: '${w.toInt()}x${h.toInt()}',
      orientation: 'landscape',
      enabled: enabled,
    );

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('kanshi_m4_'));
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  ConfigService cfgIn(Directory d) => ConfigService(
        configPath: '${d.path}/config',
        backupPrefix: '${d.path}/backups/config.bak',
        writeOptions: KanshiWriteOptions.neutral,
      );

  group('A3.3 — concurrent saves cannot clobber each other', () {
    test('the last write wins and the file is never left half-written',
        () async {
      final cfg = cfgIn(tmp);
      // Fire many overlapping saves with distinct content. Before the write
      // queue these shared one `<path>.tmp`: renames landed out of order, so
      // the file could end up holding an older render, and the losing rename
      // threw PathNotFoundException.
      final futures = <Future<void>>[];
      for (var i = 0; i < 25; i++) {
        futures.add(cfg.saveProfiles([
          Profile(name: 'P$i', monitors: [_mon(id: 'A', x: i.toDouble())]),
        ]));
      }
      await Future.wait(futures);

      final onDisk =
          KanshiConfigParser.parse(File('${tmp.path}/config').readAsStringSync());
      expect(onDisk, hasLength(1));
      expect(onDisk.single.name, 'P24',
          reason: 'the last save queued must be the one on disk');

      // No temp files left lying around next to the user's config.
      final strays = Directory(tmp.path)
          .listSync()
          .whereType<File>()
          .where((f) => f.path.contains('.tmp'))
          .toList();
      expect(strays, isEmpty);
    });

    test('a queued save persists the state it was called with', () async {
      // The controller keeps editing while a write is in flight, and Profile
      // is mutable, so the queue snapshots rather than rendering whatever the
      // model looks like when it finally runs.
      final cfg = cfgIn(tmp);
      final profile = Profile(name: 'A', monitors: [_mon(id: 'A')]);
      final first = cfg.saveProfiles([profile]);
      profile.name = 'mutated afterwards';
      await first;
      expect(
        KanshiConfigParser.parse(
                File('${tmp.path}/config').readAsStringSync())
            .single
            .name,
        'A',
      );
    });
  });

  group('A3.2 — a failed write is never reported as success', () {
    test('the save-blocked surface fires when the config cannot be written',
        () async {
      final cfg = cfgIn(tmp);
      final a = _mon(id: 'A');
      await cfg.saveProfiles([Profile(name: 'P', monitors: [a])]);

      final c = KanshiController(
        monitors: FakeMonitorService(outputs: [a]),
        config: cfg,
        mirrorRunner: FakeMirrorRunner(),
      );
      await c.init();

      String? reason;
      c.onConfigSaveBlocked = (r) => reason = r;

      // Make the config directory unwritable.
      final dir = Directory(tmp.path);
      Process.runSync('chmod', ['500', dir.path]);
      addTearDown(() => Process.runSync('chmod', ['700', dir.path]));

      // A scale change, not a drag: a lone monitor snaps back to the origin,
      // the render comes out identical, and ConfigService's skip-if-identical
      // short-circuit means no write is even attempted.
      c.scaleMonitor('A', 1.25, committing: true);
      await Future<void>.delayed(const Duration(milliseconds: 900));

      expect(reason, isNotNull,
          reason: 'a write failure must reach the user, not debugPrint');
      expect(reason, contains('kept'));
      c.dispose();
    });
  });

  group('A3.4 — restoring a backup actually restores it', () {
    test('the restored file is adopted instead of being overwritten',
        () async {
      final cfg = cfgIn(tmp);
      final a = _mon(id: 'A');
      // Save v1, then v2 — v1 becomes the newest backup.
      await cfg.saveProfiles([Profile(name: 'Original', monitors: [a])]);
      await cfg.saveProfiles([
        Profile(name: 'Edited', monitors: [_mon(id: 'A', x: 500)]),
      ]);

      final c = KanshiController(
        monitors: FakeMonitorService(outputs: [a]),
        config: cfg,
        mirrorRunner: FakeMirrorRunner(),
      );
      await c.init();
      expect(c.profiles.map((p) => p.name), contains('Edited'));

      final r = await c.restoreBackupAndApply();
      expect(r.success, isTrue, reason: r.message);

      // Previously reloadAndApply() rendered the in-memory profiles straight
      // back over the file, so the restore was undone within the same call.
      final onDisk =
          KanshiConfigParser.parse(File('${tmp.path}/config').readAsStringSync());
      expect(onDisk.map((p) => p.name), contains('Original'));
      expect(onDisk.map((p) => p.name), isNot(contains('Edited')));
      expect(c.profiles.map((p) => p.name), contains('Original'),
          reason: 'the in-memory model must adopt what was restored');
      c.dispose();
    });
  });

  group('A3.1 — the presets reach the compositor', () {
    Future<KanshiController> build(FakeMonitorService fake) async {
      final cfg = cfgIn(tmp);
      await cfg.saveProfiles([
        Profile(name: 'Desk', monitors: [
          _mon(id: 'A'),
          _mon(id: 'B', x: 4000),
        ]),
      ]);
      final c = KanshiController(
        monitors: fake,
        config: cfg,
        mirrorRunner: FakeMirrorRunner(),
      );
      await c.init();
      return c;
    }

    test('extendOutputs applies the new layout live', () async {
      final fake = FakeMonitorService(
          outputs: [_mon(id: 'A'), _mon(id: 'B', x: 4000)]);
      final c = await build(fake);
      fake.calls.clear();

      final r = await c.extendOutputs();
      expect(r.success, isTrue);
      // Before M4 the tiles moved and the toast said "Extended across all
      // outputs." while nothing was pushed to the compositor at all — and the
      // "unapplied edits" hint that might have explained it can never show in
      // the default configuration.
      expect(fake.calls.where((s) => s.startsWith('apply')), isNotEmpty,
          reason: 'the layout must actually be pushed');
      c.dispose();
    });

    test('useOnlyOutput disables the others at the compositor too', () async {
      final fake = FakeMonitorService(
          outputs: [_mon(id: 'A'), _mon(id: 'B', x: 4000)]);
      final c = await build(fake);
      fake.calls.clear();

      final r = await c.useOnlyOutput('A');
      expect(r.success, isTrue);
      expect(fake.calls.where((s) => s.startsWith('disable')), isNotEmpty);
      c.dispose();
    });

    test('a compositor refusal is reported instead of a success toast',
        () async {
      final fake = FakeMonitorService(
          outputs: [_mon(id: 'A'), _mon(id: 'B', x: 4000)]);
      final c = await build(fake);
      fake.applyResult = ProcessResult(0, 1, '', 'mode not supported');

      final r = await c.extendOutputs();
      expect(r.success, isFalse);
      expect(r.message, contains('mode not supported'));
      c.dispose();
    });

    test('staged mode still does not touch the compositor', () async {
      final fake = FakeMonitorService(
          outputs: [_mon(id: 'A'), _mon(id: 'B', x: 4000)]);
      final c = await build(fake);
      await c.setLiveApply(false);
      fake.calls.clear();

      await c.extendOutputs();
      expect(fake.calls.where((s) => s.startsWith('apply')), isEmpty,
          reason: 'with live apply off, edits stay staged until Apply');
      c.dispose();
    });
  });
}
