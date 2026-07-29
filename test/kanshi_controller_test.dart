import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kanshi_gui/services/app_settings.dart';
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
  String? mirrorOf,
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
    mirrorOf: mirrorOf,
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

  test('init() captures the connected screens when nothing matches', () async {
    final cfg = _tmpConfig(tmp);
    final fake = FakeMonitorService(outputs: [_mon(id: 'A')]);
    final c = KanshiController(monitors: fake, config: cfg);
    await c.init();
    expect(c.activeProfile?.name, equals('Setup 1'));
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

    test('setMirror evacuates the destination output before spawning wl-mirror',
        () async {
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
      fake.calls.clear();
      // Mirror A onto B. The remaining non-mirror outputs are B and C —
      // those are the legitimate evacuation targets. The destination A
      // itself must NOT appear in the targets list (would move
      // workspaces onto the very output we are about to mirror).
      final r = await c.setMirror('A', 'B');
      expect(r.success, isTrue);
      expect(fake.evacuateCalls, hasLength(1));
      expect(fake.evacuateCalls.single.dstId, equals('A'));
      expect(fake.evacuateCalls.single.targets, containsAll(['B', 'C']));
      expect(fake.evacuateCalls.single.targets, isNot(contains('A')));
      // Evacuation + settle must happen before wl-mirror spawn.
      final order = fake.calls;
      final evacIdx = order.indexOf('evacuateOutputWorkspaces');
      final waitIdx = order.indexOf('waitForOutputClear');
      expect(evacIdx, greaterThanOrEqualTo(0));
      expect(waitIdx, greaterThan(evacIdx),
          reason: 'settle wait must follow the evacuation chain');
    });

    test(
        'init evacuates the destination before spawning a mirror from a stored '
        'profile', () async {
      // Boot-time scenario: kanshi has already applied a mirror profile
      // (eDP-1 mirrors DP-1) without spawning wl-mirror — the destination
      // output sits at the source's coords with whatever workspaces sway
      // routed there. When the GUI starts and reconcile spawns wl-mirror,
      // those leftover workspaces would be buried under wl-mirror's
      // fullscreen layer. The fix: reconcile must evacuate them, same as
      // `setMirror` does.
      // Need swayDefaults so the writer persists the mirror annotation
      // across save/load — neutral options drop it.
      final cfg = ConfigService(
        configPath: '${tmp.path}/config',
        backupPrefix: '${tmp.path}/config.bak',
        writeOptions: KanshiWriteOptions.swayDefaults,
      );
      final destMon = _mon(id: 'A', x: 0, y: 0, mirrorOf: 'B');
      final srcMon = _mon(id: 'B', x: 0, y: 0);
      final otherMon = _mon(id: 'C', x: 1920, y: 0);
      await cfg.saveProfiles([
        Profile(name: 'Mirror', monitors: [destMon, srcMon, otherMon]),
      ]);
      final fake = FakeMonitorService(
        supportsMirror: true,
        outputs: [destMon, srcMon, otherMon],
      );
      final mr = FakeMirrorRunner();
      final c =
          KanshiController(monitors: fake, config: cfg, mirrorRunner: mr);
      await c.init();

      expect(fake.evacuateCalls, hasLength(1),
          reason: 'init must evacuate the soon-to-be-mirrored output');
      expect(fake.evacuateCalls.single.dstId, equals('A'));
      expect(fake.evacuateCalls.single.targets, containsAll(['B', 'C']));
      expect(fake.evacuateCalls.single.targets, isNot(contains('A')),
          reason: 'cannot use the mirror destination as an evacuation target');
      final order = fake.calls;
      final evacIdx = order.indexOf('evacuateOutputWorkspaces');
      final waitIdx = order.indexOf('waitForOutputClear');
      expect(evacIdx, greaterThanOrEqualTo(0));
      expect(waitIdx, greaterThan(evacIdx));
      expect(mr.activeDestinations, equals({'A'}),
          reason: 'wl-mirror spawn still happens after evacuation');
    });

    test(
        'subsequent reconciles do not re-evacuate a still-running mirror',
        () async {
      // Evacuation is destructive for the user (workspaces move) — it must
      // only fire when a NEW mirror is being established, not on every
      // idempotent reconcile pass triggered by hotplug noise.
      final cfg = ConfigService(
        configPath: '${tmp.path}/config',
        backupPrefix: '${tmp.path}/config.bak',
        writeOptions: KanshiWriteOptions.swayDefaults,
      );
      final destMon = _mon(id: 'A', x: 0, y: 0, mirrorOf: 'B');
      final srcMon = _mon(id: 'B', x: 0, y: 0);
      await cfg.saveProfiles([
        Profile(name: 'Mirror', monitors: [destMon, srcMon]),
      ]);
      final fake = FakeMonitorService(
        supportsMirror: true,
        outputs: [destMon, srcMon],
      );
      final mr = FakeMirrorRunner();
      final c =
          KanshiController(monitors: fake, config: cfg, mirrorRunner: mr);
      await c.init();
      expect(fake.evacuateCalls, hasLength(1));
      fake.evacuateCalls.clear();

      // Simulate a benign hotplug that doesn't change the connected set.
      fake.emitOutputs([destMon, srcMon]);
      await pumpEventQueue();
      expect(fake.evacuateCalls, isEmpty,
          reason: 'reconcile is idempotent when the mirror is already running');
    });

    test('setMirror(null) does not evacuate (only when establishing a mirror)',
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
      fake.evacuateCalls.clear();
      await c.setMirror('A', null);
      expect(fake.evacuateCalls, isEmpty,
          reason: 'un-mirroring leaves the dst free; nothing to evacuate');
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
      // Unplug and replug are two deliberate, separate events here, not one
      // dock salvo, so switch the settle barrier off for this test.
      c.hotplugSettleWindow = Duration.zero;
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

  test('a config with include directives is editable and keeps the include',
      () async {
    // This used to be refused outright: re-rendering the file from the model
    // dropped the `include` line and orphaned every profile in the included
    // files. Since M9 the save edits in place, so the line stays and the
    // user gets their app back.
    final cfgPath = '${tmp.path}/config';
    await File(cfgPath).writeAsString(
      'include /etc/kanshi.d/work\nprofile foo {\n}\n',
    );
    final cfg = ConfigService(
      configPath: cfgPath,
      backupPrefix: '${tmp.path}/config.bak',
      writeOptions: KanshiWriteOptions.neutral,
    );
    final fake = FakeMonitorService(outputs: [_mon(id: 'A')]);
    final c = KanshiController(monitors: fake, config: cfg);
    await c.init();
    expect(c.saveBlockedReason, isNull,
        reason: 'an include is no longer a reason to refuse');
    // Safe-start still holds: opening the app must not write the config at
    // all, so a hand-written config survives byte-for-byte until the user
    // makes a deliberate edit.
    expect(
      await File(cfgPath).readAsString(),
      equals('include /etc/kanshi.d/work\nprofile foo {\n}\n'),
      reason: 'Opening the app must not write to disk.',
    );

    // And a deliberate edit keeps it.
    await cfg.saveProfiles([
      Profile(name: 'foo', monitors: [_mon(id: 'A')]),
    ]);
    expect(await File(cfgPath).readAsString(),
        contains('include /etc/kanshi.d/work'));
    c.dispose();
  });

  test('opening the app does not write the kanshi config (safe-start)',
      () async {
    // The disaster we are guarding against: a first launch silently
    // rewriting (and, with kanshi auto-reload, re-applying) the user's
    // working config — which is how a friend's screens ended up overlapping
    // the moment he opened the tool. init() must capture the live setup in
    // memory only, never touch disk until the user makes a real edit.
    final cfgPath = '${tmp.path}/config';
    final cfg = ConfigService(
      configPath: cfgPath,
      backupPrefix: '${tmp.path}/config.bak',
      writeOptions: KanshiWriteOptions.neutral,
    );
    final fake = FakeMonitorService(outputs: [_mon(id: 'A'), _mon(id: 'B')]);
    final c = KanshiController(monitors: fake, config: cfg);
    await c.init();
    // Let any (erroneously) scheduled debounced save fire before asserting.
    await Future.delayed(const Duration(milliseconds: 700));
    expect(File(cfgPath).existsSync(), isFalse,
        reason: 'A fresh launch must not write or overwrite the config.');
    expect(fake.calls.where((s) => s == 'restart'), isEmpty,
        reason: 'A fresh launch must not reload/apply the compositor.');
  });

  test('hotplug events delivered after dispose are dropped without crash',
      () async {
    // `_outputSubscription?.cancel()` does NOT abort the in-flight
    // listener body if a hotplug event is delivered between dispose
    // and the runtime tearing the listener down. Without the
    // `_isDisposed` guard the body would call `notifyListeners` on a
    // disposed `ChangeNotifier` (debug assertion) and fire callbacks
    // against widgets that have already detached.
    final fake = FakeMonitorService(outputs: [_mon(id: 'A')]);
    final c = KanshiController(monitors: fake, config: _tmpConfig(tmp));
    await c.init();
    var totalNotifies = 0;
    c.addListener(() => totalNotifies++);
    c.dispose();
    // Snapshot any notifies fired during dispose itself — those come
    // from in-process scheduler/safetyNet teardown and aren't what
    // we're testing.
    final notifiesAtDispose = totalNotifies;
    // Push a hotplug — the listener body must short-circuit on the
    // `_isDisposed` flag. The assertion-level check is that this call
    // doesn't throw `FlutterError: A KanshiController was used after
    // being disposed`.
    expect(
      () => fake.emitOutputs([_mon(id: 'A'), _mon(id: 'B', x: 1920)]),
      returnsNormally,
      reason: 'Hotplug delivered after dispose must not fault.',
    );
    // Yield so any microtask the listener body might have queued has a
    // chance to run.
    await Future<void>.delayed(Duration.zero);
    expect(totalNotifies, equals(notifiesAtDispose),
        reason: 'No notifyListeners should fire from a post-dispose '
            'hotplug body.');
  });

  group('settings application', () {
    test('applyStartupSettings pushes preferences into the live objects',
        () {
      final fake = FakeMonitorService(
        outputs: [_mon(id: 'A')],
        writeOptions: KanshiWriteOptions.swayDefaults,
      );
      final mr = FakeMirrorRunner();
      final cfg = _tmpConfig(tmp);
      final c = KanshiController(monitors: fake, config: cfg, mirrorRunner: mr);
      final s = AppSettings(filePath: '${tmp.path}/s.json')
        ..mirrorScaling = MirrorScaling.cover
        ..workspaceManagement = WorkspaceManagementMode.grouped
        ..liveApply = false
        ..autoReapplyOnDrift = true;
      c.applyStartupSettings(s);
      expect(c.liveApply, isFalse);
      expect(c.autoReapplyOnDrift, isTrue);
      expect(mr.scaling, 'cover');
      // Folds into the effective write options (boot-fallback exec line).
      expect(cfg.writeOptions.mirrorScaling, 'cover');
      expect(cfg.writeOptions.workspaceDistribution,
          WorkspaceDistribution.grouped);
      expect(cfg.writeOptions.injectSwayWorkspaceExec, isTrue);
    });

    test('setMirrorScaling rewrites config and restarts mirrors', () async {
      final liveA = _mon(id: 'A');
      final liveB = _mon(id: 'B', x: 1920);
      final cfg = ConfigService(
        configPath: '${tmp.path}/config',
        backupPrefix: '${tmp.path}/config.bak',
        writeOptions: KanshiWriteOptions.swayDefaults,
      );
      await cfg.saveProfiles([
        // B mirrors A so the writer emits a `exec wl-mirror --scaling …` line.
        Profile(name: 'M', monitors: [
          _mon(id: 'A'),
          _mon(id: 'B', x: 1920, mirrorOf: 'A'),
        ]),
      ]);
      final fake = FakeMonitorService(
        outputs: [liveA, liveB],
        supportsMirror: true,
        writeOptions: KanshiWriteOptions.swayDefaults,
      );
      final mr = FakeMirrorRunner();
      final c = KanshiController(monitors: fake, config: cfg, mirrorRunner: mr);
      await c.init();
      await c.setMirrorScaling('exact');
      expect(mr.scaling, 'exact');
      expect(cfg.writeOptions.mirrorScaling, 'exact');
      // The rewritten kanshi config carries the new scaling in its
      // boot-fallback exec line.
      final written = await File('${tmp.path}/config').readAsString();
      expect(written, contains('--scaling exact'));
    });
  });

  group('verify-and-fix workspace placement on init', () {
    test('reapplies the chain when live workspace_outputs disagree with ranks',
        () async {
      // Cold-boot scenario: the kanshi `exec swaymsg "…"` ran during
      // sway's output discovery and lost the race, so workspaces 1
      // and 2 ended up on the wrong outputs. The controller must
      // detect the mismatch and reapply the chain.
      final cfg = _tmpConfig(tmp);
      final liveA = _mon(id: 'A');
      final liveB = _mon(id: 'B', x: 1920);
      await cfg.saveProfiles([
        Profile(name: 'Desk', monitors: [liveA, liveB]),
      ]);
      final fake = FakeMonitorService(
        outputs: [liveA, liveB],
        writeOptions: KanshiWriteOptions.swayDefaults,
      )..workspaceOutputs = {1: 'B', 2: 'A'};
      final c = KanshiController(
        monitors: fake,
        config: cfg,
        workspaceDistribution: WorkspaceDistribution.interleaved,
      );
      await c.init();
      expect(fake.workspaceChainCalls, hasLength(1),
          reason: 'A mismatched workspace mapping must trigger a reapply.');
      final chain = fake.workspaceChainCalls.single;
      expect(chain, contains("workspace 1 output 'A'"));
      expect(chain, contains("workspace 2 output 'B'"));
      expect(chain.split('; ').last, equals('workspace number 1'));
    });

    test('does not reapply when live mapping already matches the desired ranks',
        () async {
      final cfg = _tmpConfig(tmp);
      final liveA = _mon(id: 'A');
      final liveB = _mon(id: 'B', x: 1920);
      await cfg.saveProfiles([
        Profile(name: 'Desk', monitors: [liveA, liveB]),
      ]);
      final fake = FakeMonitorService(
        outputs: [liveA, liveB],
        writeOptions: KanshiWriteOptions.swayDefaults,
      )..workspaceOutputs = {1: 'A', 2: 'B'};
      final c = KanshiController(
        monitors: fake,
        config: cfg,
        workspaceDistribution: WorkspaceDistribution.interleaved,
      );
      await c.init();
      expect(fake.workspaceChainCalls, isEmpty,
          reason: 'A correct mapping must NOT trigger a redundant reapply.');
    });

    test('skips workspaces sway has not created yet', () async {
      // On a quiet boot sway may only have ws 1 created (the focused
      // initial workspace). Absence is not mismatch — the chain's
      // `workspace N output X` already declared the home for any
      // future workspace. We only reapply when an *existing*
      // workspace lives on the wrong output.
      final cfg = _tmpConfig(tmp);
      final liveA = _mon(id: 'A');
      final liveB = _mon(id: 'B', x: 1920);
      await cfg.saveProfiles([
        Profile(name: 'Desk', monitors: [liveA, liveB]),
      ]);
      final fake = FakeMonitorService(
        outputs: [liveA, liveB],
        writeOptions: KanshiWriteOptions.swayDefaults,
      )..workspaceOutputs = {1: 'A'};
      final c = KanshiController(
        monitors: fake,
        config: cfg,
        workspaceDistribution: WorkspaceDistribution.interleaved,
      );
      await c.init();
      expect(fake.workspaceChainCalls, isEmpty,
          reason:
              'A partial live mapping that agrees with the ranks for the '
              'existing workspace must not trigger a reapply.');
    });

    test('skips entirely on backends without injectSwayWorkspaceExec',
        () async {
      // Non-Sway compositors (wlr-randr / niri / etc.) use
      // `KanshiWriteOptions.neutral`, which doesn't emit the workspace
      // chain in the first place. Asking sway-shaped IPC questions on
      // those backends would be a wasted round-trip and would also
      // misbehave if `getWorkspaceOutputs` ever returned something
      // non-empty by mistake. Gate the whole verify path explicitly.
      final cfg = _tmpConfig(tmp);
      final liveA = _mon(id: 'A');
      final liveB = _mon(id: 'B', x: 1920);
      await cfg.saveProfiles([
        Profile(name: 'Desk', monitors: [liveA, liveB]),
      ]);
      final fake = FakeMonitorService(
        outputs: [liveA, liveB],
        // Default for non-Sway backends.
        writeOptions: KanshiWriteOptions.neutral,
      )..workspaceOutputs = {1: 'B', 2: 'A'};
      // Opt in deliberately: this proves the *backend* gate holds even when
      // the user has workspace management turned on — a neutral backend
      // still never touches workspaces.
      final c = KanshiController(
        monitors: fake,
        config: cfg,
        workspaceDistribution: WorkspaceDistribution.interleaved,
      );
      await c.init();
      expect(fake.workspaceChainCalls, isEmpty,
          reason: 'Non-Sway backend must not invoke the chain.');
      expect(fake.calls.where((c) => c == 'getWorkspaceOutputs'), isEmpty,
          reason: 'Non-Sway backend must not even read workspace state.');
    });

    test('excludes mirror destinations from the desired ranks', () async {
      // A 2-monitor profile with B mirroring A has only 1 ranked
      // output — the mirror destination is occluded by wl-mirror.
      // If the live mapping has ws 1 on A (the only rank), no
      // reapply. If it's on B (which shouldn't happen in steady
      // state but might during a race), reapply with chain that
      // sends *every* ws to A.
      // Need the writer to preserve the mirror annotation across the
      // round-trip — neutral options drop it. Use swayDefaults here.
      final cfg = ConfigService(
        configPath: '${tmp.path}/config',
        backupPrefix: '${tmp.path}/config.bak',
        writeOptions: KanshiWriteOptions.swayDefaults,
      );
      final liveA = _mon(id: 'A');
      final liveB = _mon(id: 'B', x: 1920);
      final profile = Profile(name: 'Mirror', monitors: [
        _mon(id: 'A'),
        _mon(id: 'B', x: 1920, mirrorOf: 'A'),
      ]);
      await cfg.saveProfiles([profile]);
      final fake = FakeMonitorService(
        outputs: [liveA, liveB],
        writeOptions: KanshiWriteOptions.swayDefaults,
      )..workspaceOutputs = {1: 'B'};
      final c = KanshiController(
        monitors: fake,
        config: cfg,
        workspaceDistribution: WorkspaceDistribution.interleaved,
      );
      await c.init();
      expect(fake.workspaceChainCalls, hasLength(1));
      final chain = fake.workspaceChainCalls.single;
      // Every workspace target (1..9) must reference A only.
      for (var ws = 1; ws <= 9; ws++) {
        expect(chain, contains("workspace $ws output 'A'"));
      }
      expect(chain, isNot(contains("output 'B'")));
    });

    test('orphan ws above maxWorkspaces triggers a chain reapply', () async {
      // Scenario the user actually hit: after a setMirror(null) that
      // un-mirrored a destination, an old ws 10 was still sitting on
      // the freshly-promoted output. The desired map only covers 1..9
      // so the simple mismatch check missed it. Detect ws-out-of-range
      // separately and re-fire the chain so its `workspace number 2..9`
      // dance displaces the orphan visible workspace; sway then garbage-
      // collects the now-empty ws 10.
      final cfg = _tmpConfig(tmp);
      final liveA = _mon(id: 'A');
      final liveB = _mon(id: 'B', x: 1920);
      await cfg.saveProfiles([
        Profile(name: 'Desk', monitors: [liveA, liveB]),
      ]);
      final fake = FakeMonitorService(
        outputs: [liveA, liveB],
        writeOptions: KanshiWriteOptions.swayDefaults,
      )..workspaceOutputs = {
          1: 'A',
          2: 'B',
          10: 'B',
        };
      final c = KanshiController(
        monitors: fake,
        config: cfg,
        workspaceDistribution: WorkspaceDistribution.interleaved,
      );
      await c.init();
      expect(fake.workspaceChainCalls, hasLength(1),
          reason: 'Orphan ws > 9 must trigger reapply even when the 1..9 '
              'mapping is otherwise clean.');
    });

    test('default (no opt-in) leaves workspaces untouched on Sway', () async {
      // The opt-in guarantee that protects new users: even on a Sway
      // backend with a clear live mismatch, a controller constructed with
      // no workspace distribution (the default) must NOT run the chain or
      // even read live workspace state.
      final cfg = _tmpConfig(tmp);
      final liveA = _mon(id: 'A');
      final liveB = _mon(id: 'B', x: 1920);
      await cfg.saveProfiles([
        Profile(name: 'Desk', monitors: [liveA, liveB]),
      ]);
      final fake = FakeMonitorService(
        outputs: [liveA, liveB],
        writeOptions: KanshiWriteOptions.swayDefaults,
      )..workspaceOutputs = {1: 'B', 2: 'A'};
      final c = KanshiController(monitors: fake, config: cfg);
      await c.init();
      expect(fake.workspaceChainCalls, isEmpty,
          reason: 'Workspace management is opt-in; the default must not '
              'reshuffle a new user\'s workspaces.');
      expect(fake.calls.where((c) => c == 'getWorkspaceOutputs'), isEmpty,
          reason: 'Opted-out controller must not even read workspace state.');
    });

    test('grouped mode lands contiguous bands per output', () async {
      final cfg = _tmpConfig(tmp);
      final liveA = _mon(id: 'A');
      final liveB = _mon(id: 'B', x: 1920);
      await cfg.saveProfiles([
        Profile(name: 'Desk', monitors: [liveA, liveB]),
      ]);
      final fake = FakeMonitorService(
        outputs: [liveA, liveB],
        writeOptions: KanshiWriteOptions.swayDefaults,
        // Force a mismatch so the chain reapplies and we can inspect it.
      )..workspaceOutputs = {1: 'B'};
      final c = KanshiController(
        monitors: fake,
        config: cfg,
        workspaceDistribution: WorkspaceDistribution.grouped,
      );
      await c.init();
      expect(fake.workspaceChainCalls, hasLength(1));
      final chain = fake.workspaceChainCalls.single;
      // Grouped over 2 outputs: ws 1..5 → A, ws 6..9 → B.
      for (var ws = 1; ws <= 5; ws++) {
        expect(chain, contains("workspace $ws output 'A'"));
      }
      for (var ws = 6; ws <= 9; ws++) {
        expect(chain, contains("workspace $ws output 'B'"));
      }
    });
  });

  group('quick-layout presets', () {
    test('extendOutputs lays enabled outputs flush in a row, clears mirror',
        () async {
      final cfg = _tmpConfig(tmp);
      final fake = FakeMonitorService(
        outputs: [_mon(id: 'A', x: 0), _mon(id: 'B', x: 500, mirrorOf: 'A')],
        supportsMirror: true,
      );
      final c = KanshiController(monitors: fake, config: cfg);
      await c.init();
      final r = await c.extendOutputs();
      expect(r.success, isTrue);
      final a = c.activeMonitors.firstWhere((m) => m.id == 'A');
      final b = c.activeMonitors.firstWhere((m) => m.id == 'B');
      expect(a.x, 0);
      expect(b.x, 1920, reason: 'B sits flush to the right of A');
      expect([a.y, b.y], everyElement(0));
      expect(a.mirrorOf, isNull);
      expect(b.mirrorOf, isNull);
    });

    test('mirrorAll points every other output at the leftmost', () async {
      final cfg = _tmpConfig(tmp);
      final fake = FakeMonitorService(
        outputs: [_mon(id: 'A', x: 0), _mon(id: 'B', x: 1920)],
        supportsMirror: true,
      );
      final c = KanshiController(monitors: fake, config: cfg);
      await c.init();
      final r = await c.mirrorAll();
      expect(r.success, isTrue);
      expect(c.activeMonitors.firstWhere((m) => m.id == 'A').mirrorOf, isNull);
      expect(c.activeMonitors.firstWhere((m) => m.id == 'B').mirrorOf, 'A');
    });

    test('mirrorAll is rejected without mirror support', () async {
      final cfg = _tmpConfig(tmp);
      final fake = FakeMonitorService(
        outputs: [_mon(id: 'A'), _mon(id: 'B', x: 1920)],
      );
      final c = KanshiController(monitors: fake, config: cfg);
      await c.init();
      expect((await c.mirrorAll()).success, isFalse);
    });

    test('useOnlyOutput enables the target and disables the rest', () async {
      final cfg = _tmpConfig(tmp);
      final fake = FakeMonitorService(
        outputs: [_mon(id: 'A', x: 0), _mon(id: 'B', x: 1920)],
      );
      final c = KanshiController(monitors: fake, config: cfg);
      await c.init();
      final r = await c.useOnlyOutput('A');
      expect(r.success, isTrue);
      expect(c.activeMonitors.firstWhere((m) => m.id == 'A').enabled, isTrue);
      expect(c.activeMonitors.firstWhere((m) => m.id == 'B').enabled, isFalse);
    });
  });

  group('apply safety net & dirty state', () {
    test('a preset marks the layout dirty; applying clears it', () async {
      final cfg = _tmpConfig(tmp);
      final fake = FakeMonitorService(
        outputs: [_mon(id: 'A', x: 0), _mon(id: 'B', x: 1920)],
      );
      final c = KanshiController(monitors: fake, config: cfg);
      await c.init();
      c.liveApply = false; // dirty tracking only applies in staged mode
      expect(c.hasUnappliedEdits, isFalse);
      c.extendOutputs();
      expect(c.hasUnappliedEdits, isTrue);
      await c.reloadAndApply();
      expect(c.hasUnappliedEdits, isFalse);
    });

    test('live apply means nothing is ever "unapplied"', () async {
      final cfg = _tmpConfig(tmp);
      final fake = FakeMonitorService(
        outputs: [_mon(id: 'A', x: 0), _mon(id: 'B', x: 1920)],
      );
      final c = KanshiController(monitors: fake, config: cfg);
      await c.init();
      expect(c.liveApply, isTrue, reason: 'live apply is the default');
      c.extendOutputs();
      expect(c.hasUnappliedEdits, isFalse,
          reason: 'with live apply on, edits are applied immediately');
    });

    test('reloadAndApply arms the auto-revert safety net', () async {
      final cfg = _tmpConfig(tmp);
      final fake = FakeMonitorService(
        outputs: [_mon(id: 'A', x: 0), _mon(id: 'B', x: 1920)],
      );
      final c = KanshiController(monitors: fake, config: cfg);
      await c.init();
      c.autoRevertOnApply = true; // opt in — off by default
      await c.reloadAndApply();
      expect(c.safetyNet.activePrompt?.key, equals('layout-apply'));
    });

    test('reloadAndApply does NOT arm the safety net by default', () async {
      final cfg = _tmpConfig(tmp);
      final fake = FakeMonitorService(
        outputs: [_mon(id: 'A', x: 0), _mon(id: 'B', x: 1920)],
      );
      final c = KanshiController(monitors: fake, config: cfg);
      await c.init();
      await c.reloadAndApply();
      expect(c.safetyNet.activePrompt, isNull,
          reason: 'Routine applies must not pop a countdown banner.');
    });

    test('auto-revert restores the previously-applied config', () async {
      final cfgPath = '${tmp.path}/config';
      final cfg = ConfigService(
        configPath: cfgPath,
        backupPrefix: '${tmp.path}/config.bak',
        writeOptions: KanshiWriteOptions.neutral,
      );
      final fake = FakeMonitorService(
        outputs: [_mon(id: 'A', x: 0), _mon(id: 'B', x: 1920)],
      );
      final c = KanshiController(monitors: fake, config: cfg);
      await c.init();
      c.autoRevertOnApply = true; // opt in — off by default
      // Establish a baseline on disk and keep it.
      await c.reloadAndApply();
      c.safetyNet.confirm('layout-apply');
      final baseline = await File(cfgPath).readAsString();
      // Make a change and apply it.
      c.useOnlyOutput('A');
      await c.reloadAndApply();
      expect(await File(cfgPath).readAsString(), isNot(equals(baseline)));
      // The safety net must roll back to the baseline, not the new layout.
      await c.safetyNet.revertNow('layout-apply');
      expect(await File(cfgPath).readAsString(), equals(baseline));
    });
  });
}
