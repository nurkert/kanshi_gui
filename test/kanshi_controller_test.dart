import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kanshi_gui/models/monitor_mode.dart';
import 'package:kanshi_gui/models/monitor_tile_data.dart';
import 'package:kanshi_gui/models/profiles.dart';
import 'package:kanshi_gui/services/config_service.dart';
import 'package:kanshi_gui/services/kanshi_config_writer.dart';
import 'package:kanshi_gui/state/kanshi_controller.dart';

import 'fakes/fake_mirror_runner.dart';
import 'fakes/fake_monitor_service.dart';

MonitorTileData _mon({
  String id = 'M',
  bool enabled = true,
  double w = 1920,
  double h = 1080,
  double x = 0,
  double y = 0,
  double scale = 1.0,
  int rotation = 0,
  double refresh = 60,
  List<MonitorMode> modes = const [],
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
    modes: modes,
  );
}

ConfigService _tmpConfig(Directory dir) => ConfigService(
      configPath: '${dir.path}/config',
      backupPrefix: '${dir.path}/config.bak',
      writeOptions: KanshiWriteOptions.neutral,
    );

void main() {
  late Directory tmp;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('kanshi_gui_test_');
  });
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('init() loads profiles and picks the active one matching live outputs',
      () async {
    final liveA = _mon(id: 'A');
    final liveB = _mon(id: 'B', x: 1920);
    final cfg = _tmpConfig(tmp);
    await cfg.saveProfiles([
      Profile(name: 'Other', monitors: [_mon(id: 'X')]),
      Profile(name: 'Match', monitors: [liveA, liveB]),
    ]);
    final fake = FakeMonitorService(outputs: [liveA, liveB]);
    final c = KanshiController(monitors: fake, config: cfg);
    await c.init();
    expect(c.profiles.map((p) => p.name).toList(),
        containsAll(['Other', 'Match']));
    expect(c.activeProfile?.name, equals('Match'));
  });

  test('init() creates a Current Setup when nothing matches', () async {
    final cfg = _tmpConfig(tmp);
    final fake = FakeMonitorService(outputs: [_mon(id: 'A')]);
    final c = KanshiController(monitors: fake, config: cfg);
    await c.init();
    expect(c.activeProfile?.name, equals('Current Setup'));
  });

  test('renameProfile rejects duplicates', () async {
    final cfg = _tmpConfig(tmp);
    await cfg.saveProfiles([
      Profile(name: 'A', monitors: [_mon(id: 'X')]),
      Profile(name: 'B', monitors: [_mon(id: 'Y')]),
    ]);
    final c = KanshiController(
        monitors: FakeMonitorService(), config: cfg);
    await c.init();
    final r = c.renameProfile(0, 'B');
    expect(r.success, isFalse);
    expect(r.message, contains('already exists'));
  });

  test('toggleEnabled flips state when the compositor confirms', () async {
    final cfg = _tmpConfig(tmp);
    // Two enabled outputs so the hard-block doesn't trip.
    final fake = FakeMonitorService(outputs: [_mon(id: 'A'), _mon(id: 'B')]);
    final c = KanshiController(monitors: fake, config: cfg);
    await c.init();
    fake.outputs = [_mon(id: 'A', enabled: false), _mon(id: 'B')];
    final r = await c.toggleEnabled('A', false);
    expect(r.success, isTrue);
    expect(fake.calls, contains('disable A'));
    expect(c.activeMonitors.firstWhere((m) => m.id == 'A').enabled, isFalse);
  });

  test('applyMode updates the active monitor and calls compositor when enabled',
      () async {
    final cfg = _tmpConfig(tmp);
    final fake = FakeMonitorService(outputs: [_mon(id: 'A')]);
    final c = KanshiController(monitors: fake, config: cfg);
    await c.init();
    final r = await c.applyMode(
        'A', MonitorMode(width: 2560, height: 1440, refresh: 60));
    expect(r.success, isTrue);
    expect(fake.calls.any((s) => s.startsWith('setMode A')), isTrue);
    expect(c.activeMonitors.first.width, equals(2560));
    expect(c.activeMonitors.first.height, equals(1440));
  });

  test('reloadAndApply restarts the compositor and reports failure', () async {
    final cfg = _tmpConfig(tmp);
    final fake = FakeMonitorService(
      outputs: [_mon(id: 'A')],
      restartResult: ProcessResult(0, 1, '', 'boom'),
    );
    final c = KanshiController(monitors: fake, config: cfg);
    await c.init();
    final r = await c.reloadAndApply();
    expect(r.success, isFalse);
    expect(r.message, contains('boom'));
  });

  test('toggleEnabled refuses to disable the last enabled output', () async {
    final cfg = _tmpConfig(tmp);
    final fake = FakeMonitorService(outputs: [_mon(id: 'A')]);
    final c = KanshiController(monitors: fake, config: cfg);
    await c.init();
    final r = await c.toggleEnabled('A', false);
    expect(r.success, isFalse);
    expect(r.message, contains('last enabled'));
    expect(fake.calls, isNot(contains('disable A')));
  });

  test('pushLiveApply forwards a single apply call to the backend', () async {
    final cfg = _tmpConfig(tmp);
    final fake = FakeMonitorService(outputs: [_mon(id: 'A')]);
    final c = KanshiController(monitors: fake, config: cfg);
    await c.init();
    final r = await c.pushLiveApply(c.activeMonitors.first);
    expect(r.success, isTrue);
    expect(fake.calls.where((s) => s.startsWith('apply A')), hasLength(1));
  });

  test('pushLiveApply is a no-op for disabled monitors', () async {
    final cfg = _tmpConfig(tmp);
    final fake = FakeMonitorService(outputs: [_mon(id: 'A', enabled: false)]);
    final c = KanshiController(monitors: fake, config: cfg);
    await c.init();
    final before = fake.calls.length;
    final r = await c.pushLiveApply(c.activeMonitors.first);
    expect(r.success, isTrue);
    expect(fake.calls.length, equals(before));
  });

  test('beginDragSession pins layout bounds, endDragSession releases them',
      () async {
    final cfg = _tmpConfig(tmp);
    final fake = FakeMonitorService(outputs: [
      _mon(id: 'A', x: 0, y: 0),
      _mon(id: 'B', x: 1920, y: 0),
    ]);
    final c = KanshiController(monitors: fake, config: cfg);
    await c.init();

    expect(c.pinnedLayoutBounds, isNull,
        reason: 'No pin outside of an active drag.');

    c.beginDragSession('B');
    final pinned = c.pinnedLayoutBounds;
    expect(pinned, isNotNull);
    expect(pinned!.left, equals(0));
    expect(pinned.top, equals(0));
    expect(pinned.right, equals(3840));
    expect(pinned.bottom, equals(1080));

    // Even after the dragged tile reports a far-negative position the pin
    // does not change — that's the whole point: the canvas stays put while
    // the drag is in progress so non-dragged tiles do not slide.
    c.updateMonitor(c.activeMonitors
        .firstWhere((m) => m.id == 'B')
        .copyWith(x: -5000, y: -5000));
    expect(c.pinnedLayoutBounds, equals(pinned));

    c.endDragSession('B');
    expect(c.pinnedLayoutBounds, isNull);
  });

  test('hotplug while dragging releases the layout pin and ends the drag',
      () async {
    final cfg = _tmpConfig(tmp);
    final fake = FakeMonitorService(outputs: [
      _mon(id: 'A', x: 0, y: 0),
      _mon(id: 'B', x: 1920, y: 0),
    ]);
    final c = KanshiController(monitors: fake, config: cfg);
    await c.init();
    c.beginDragSession('B');
    expect(c.pinnedLayoutBounds, isNotNull);
    // Yank B mid-drag.
    fake.emitOutputs([_mon(id: 'A', x: 0, y: 0)]);
    await Future<void>.delayed(Duration.zero); // let the stream listener run
    expect(c.pinnedLayoutBounds, isNull,
        reason: 'A vanished dragged tile must release the pin so the next '
            'drag does not project against a stale bounding box.');
  });

  test('setActiveProfile clears the custom-mode revert memory', () async {
    final cfg = _tmpConfig(tmp);
    final fake = FakeMonitorService(outputs: [
      _mon(id: 'A', x: 0, y: 0),
    ]);
    final c = KanshiController(monitors: fake, config: cfg);
    await c.init();
    // Apply a custom mode → seeds the revert memory for output A.
    await c.applyCustomMode('A', 1280, 720, 60);
    // A second profile mirroring the same hardware so we can switch.
    c.createProfileFromCurrentSetup();
    expect(c.profiles.length, greaterThanOrEqualTo(2));
    c.setActiveProfile(0);
    final r = await c.revertCustomMode('A');
    expect(r.success, isFalse,
        reason: 'Profile switch must drop the prior-mode cache so a revert '
            'in the new profile context cannot replay an unrelated mode.');
  });

  test('rehydration prefers exact id over manufacturer for identical EDID',
      () async {
    // Two physical Samsungs, one on DP-1 and one on DP-2, same make/model.
    // The first call to refreshConnectedMonitors must not collapse both
    // profile entries onto whichever output appears first in the list.
    final cfg = _tmpConfig(tmp);
    final fake = FakeMonitorService(outputs: [
      _mon(id: 'DP-1', x: 0, y: 0),
      _mon(id: 'DP-2', x: 1920, y: 0),
    ]);
    // Tag both as identical manufacturer to simulate same EDID.
    fake.outputs = fake.outputs
        .map((m) => MonitorTileData(
              id: m.id,
              manufacturer: 'Samsung 2560x1440',
              x: m.x,
              y: m.y,
              width: m.width,
              height: m.height,
              scale: 1.0,
              rotation: 0,
              refresh: 60,
              resolution: m.resolution,
              orientation: 'landscape',
              modes: const [],
              enabled: true,
            ))
        .toList();
    final c = KanshiController(monitors: fake, config: cfg);
    await c.init();
    await c.refreshConnectedMonitors();
    // Each profile entry must be matched to a different live output.
    final ids = c.activeMonitors.map((m) => m.id).toSet();
    expect(ids, containsAll({'DP-1', 'DP-2'}),
        reason: 'Identical-EDID monitors must keep their distinct ids.');
    expect(ids.length, equals(2),
        reason: 'No two profile entries may collapse onto the same output.');
  });

  group('mirror', () {
    test('setMirror is rejected when backend does not support mirror',
        () async {
      final cfg = _tmpConfig(tmp);
      // FakeMonitorService default: supportsMirror = false.
      final fake = FakeMonitorService(outputs: [
        _mon(id: 'A', x: 0, y: 0),
        _mon(id: 'B', x: 1920, y: 0),
      ]);
      final mr = FakeMirrorRunner();
      final c =
          KanshiController(monitors: fake, config: cfg, mirrorRunner: mr);
      await c.init();
      final r = await c.setMirror('A', 'B');
      expect(r.success, isFalse);
      expect(mr.calls, isEmpty);
    });

    test('setMirror starts wl-mirror and updates the profile', () async {
      final cfg = _tmpConfig(tmp);
      final fake = FakeMonitorService(
        supportsMirror: true,
        outputs: [
          _mon(id: 'A', x: 0, y: 0),
          _mon(id: 'B', x: 1920, y: 0),
        ],
      );
      final mr = FakeMirrorRunner();
      final c =
          KanshiController(monitors: fake, config: cfg, mirrorRunner: mr);
      await c.init();
      final r = await c.setMirror('A', 'B');
      expect(r.success, isTrue);
      expect(mr.activeDestinations, equals({'A'}));
      expect(mr.mirrorSourceFor('A'), equals('B'));
      expect(c.activeMonitors.firstWhere((m) => m.id == 'A').mirrorOf,
          equals('B'));
    });

    test('setMirror(null) tears down the wl-mirror process', () async {
      final cfg = _tmpConfig(tmp);
      final fake = FakeMonitorService(
        supportsMirror: true,
        outputs: [
          _mon(id: 'A', x: 0, y: 0),
          _mon(id: 'B', x: 1920, y: 0),
        ],
      );
      final mr = FakeMirrorRunner();
      final c =
          KanshiController(monitors: fake, config: cfg, mirrorRunner: mr);
      await c.init();
      await c.setMirror('A', 'B');
      mr.calls.clear();
      final r = await c.setMirror('A', null);
      expect(r.success, isTrue);
      expect(mr.activeDestinations, isEmpty);
      expect(mr.calls, contains('stop A'));
      expect(c.activeMonitors.firstWhere((m) => m.id == 'A').mirrorOf,
          isNull);
    });

    test('setMirror rejects self-mirror', () async {
      final cfg = _tmpConfig(tmp);
      final fake = FakeMonitorService(
        supportsMirror: true,
        outputs: [_mon(id: 'A', x: 0, y: 0)],
      );
      final c = KanshiController(
          monitors: fake, config: cfg, mirrorRunner: FakeMirrorRunner());
      await c.init();
      final r = await c.setMirror('A', 'A');
      expect(r.success, isFalse);
    });

    test('setMirror rejects mirror chains (A→B then B→C)', () async {
      final cfg = _tmpConfig(tmp);
      final fake = FakeMonitorService(
        supportsMirror: true,
        outputs: [
          _mon(id: 'A', x: 0, y: 0),
          _mon(id: 'B', x: 1920, y: 0),
          _mon(id: 'C', x: 3840, y: 0),
        ],
      );
      final mr = FakeMirrorRunner();
      final c =
          KanshiController(monitors: fake, config: cfg, mirrorRunner: mr);
      await c.init();
      // First: B→C (B mirrors C). Now B has mirrorOf=C.
      var r = await c.setMirror('B', 'C');
      expect(r.success, isTrue);
      // Then attempt A→B — refused, because B is itself a mirror dst.
      r = await c.setMirror('A', 'B');
      expect(r.success, isFalse);
      expect(mr.mirrorSourceFor('A'), isNull);
    });

    test('setMirror rejects circular A→B when B→A already exists',
        () async {
      final cfg = _tmpConfig(tmp);
      final fake = FakeMonitorService(
        supportsMirror: true,
        outputs: [
          _mon(id: 'A', x: 0, y: 0),
          _mon(id: 'B', x: 1920, y: 0),
        ],
      );
      final mr = FakeMirrorRunner();
      final c =
          KanshiController(monitors: fake, config: cfg, mirrorRunner: mr);
      await c.init();
      // Set up A mirrors B.
      await c.setMirror('A', 'B');
      // Now B→A would close the loop. Refused.
      // (Refused via the mirror-chain rule: A is already a mirror dst,
      // so it can't be a source.)
      final r = await c.setMirror('B', 'A');
      expect(r.success, isFalse);
    });

    test('switching to a profile with no mirrors stops the running ones',
        () async {
      final cfg = _tmpConfig(tmp);
      final fake = FakeMonitorService(
        supportsMirror: true,
        outputs: [
          _mon(id: 'A', x: 0, y: 0),
          _mon(id: 'B', x: 1920, y: 0),
        ],
      );
      final mr = FakeMirrorRunner();
      final c =
          KanshiController(monitors: fake, config: cfg, mirrorRunner: mr);
      await c.init();
      await c.setMirror('A', 'B');
      // Add a second profile and switch to it.
      c.createProfileFromCurrentSetup();
      // The new profile copies activeMonitors but the dragged setMirror
      // already updated the original profile, so the new profile starts
      // mirror-free.
      c.setActiveProfile(c.profiles.length - 1);
      // Wait one microtask so the discarded-future _reconcileMirrors runs.
      await Future<void>.delayed(Duration.zero);
      expect(mr.activeDestinations, isEmpty,
          reason: 'Profile switch must tear down the previous mirrors.');
    });

    test('hotplug of a missing source spawns once it reconnects', () async {
      final cfg = _tmpConfig(tmp);
      final fake = FakeMonitorService(
        supportsMirror: true,
        outputs: [_mon(id: 'A', x: 0, y: 0)],
      );
      final mr = FakeMirrorRunner();
      final c =
          KanshiController(monitors: fake, config: cfg, mirrorRunner: mr);
      await c.init();
      // Profile has A and B with B→A mirror, but B isn't connected yet.
      // Manually inject B into the profile to simulate that scenario.
      // Use createProfileFromCurrentSetup then add B by editing.
      // Easier: include B in fake outputs from the start, set mirror,
      // then disconnect B and reconnect.
      fake.outputs = [
        _mon(id: 'A', x: 0, y: 0),
        _mon(id: 'B', x: 1920, y: 0),
      ];
      await c.refreshConnectedMonitors();
      c.createProfileFromCurrentSetup();
      await c.setMirror('B', 'A');
      expect(mr.activeDestinations, contains('B'));
      // B unplugs.
      fake.emitOutputs([_mon(id: 'A', x: 0, y: 0)]);
      await Future<void>.delayed(Duration.zero);
      expect(mr.activeDestinations, isNot(contains('B')),
          reason: 'Mirror must stop when destination is unplugged.');
      // B comes back.
      fake.emitOutputs([
        _mon(id: 'A', x: 0, y: 0),
        _mon(id: 'B', x: 1920, y: 0),
      ]);
      await Future<void>.delayed(Duration.zero);
      expect(mr.activeDestinations, contains('B'),
          reason: 'Mirror must auto-respawn on destination reconnect.');
    });
  });

  test('identifyDisplays spawns a per-output banner when supported',
      () async {
    final cfg = _tmpConfig(tmp);
    final fake = FakeMonitorService(
      outputs: [
        _mon(id: 'A', x: 0, y: 0),
        _mon(id: 'B', x: 1920, y: 0),
        _mon(id: 'C', x: 3840, y: 0, enabled: false),
      ],
    );
    fake.identifyBannerSupported = true;
    final c = KanshiController(monitors: fake, config: cfg);
    await c.init();
    c.identifyDisplays();
    // One banner per ENABLED tile, with the matching number, in
    // top-to-bottom + left-to-right order.
    expect(fake.identifyBannerCalls,
        equals([
          ['A', '1'],
          ['B', '2'],
        ]),
        reason:
            'Disabled tiles must not get banners; numbers match GUI order.');
  });

  test('identifyDisplays numbers mirror destinations alongside their sources',
      () async {
    final cfg = _tmpConfig(tmp);
    final fake = FakeMonitorService(
      supportsMirror: true,
      outputs: [
        _mon(id: 'A', x: 0, y: 0),
        _mon(id: 'B', x: 1920, y: 0),
      ],
    );
    fake.identifyBannerSupported = true;
    final mr = FakeMirrorRunner();
    final c =
        KanshiController(monitors: fake, config: cfg, mirrorRunner: mr);
    await c.init();
    // Wire B to mirror A — B is now the destination, A the source.
    final r = await c.setMirror('B', 'A');
    expect(r.success, isTrue);
    c.identifyDisplays();
    // Both tiles must end up in `identifyNumbers` — the destination
    // gets a number too so the source tile can render it as a chip.
    expect(c.identifyNumbers, hasLength(2));
    expect(c.identifyNumbers['A'], isNotNull);
    expect(c.identifyNumbers['B'], isNotNull);
  });

  test(
      'identifyDisplays skips swaynag for mirror destinations to avoid '
      'double-painting the source pixels', () async {
    final cfg = _tmpConfig(tmp);
    final fake = FakeMonitorService(
      supportsMirror: true,
      outputs: [
        _mon(id: 'A', x: 0, y: 0),
        _mon(id: 'B', x: 1920, y: 0),
      ],
    );
    fake.identifyBannerSupported = true;
    final mr = FakeMirrorRunner();
    final c =
        KanshiController(monitors: fake, config: cfg, mirrorRunner: mr);
    await c.init();
    await c.setMirror('B', 'A');
    fake.identifyBannerCalls.clear();
    c.identifyDisplays();
    // Only A — B's banner would be hidden behind wl-mirror's fullscreen
    // window anyway, AND would also paint twice on the source via the
    // mirror, so the controller must skip B's banner spawn entirely.
    expect(fake.identifyBannerCalls.map((c) => c.first).toList(),
        equals(['A']));
  });

  test('controller propagates writeOptions from backend to ConfigService', () {
    final fake = FakeMonitorService(
        writeOptions: KanshiWriteOptions.neutral);
    // Start with sway defaults — the controller must override to neutral
    // because the active backend is wlr-randr-style.
    final cfg = ConfigService(
      configPath: '${tmp.path}/c',
      backupPrefix: '${tmp.path}/c.bak',
      writeOptions: KanshiWriteOptions.swayDefaults,
    );
    KanshiController(monitors: fake, config: cfg);
    expect(cfg.writeOptions.injectSwayWorkspaceExec, isFalse);
  });
}
