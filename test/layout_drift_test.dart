// Hardening test for the kanshi-daemon hotplug race: after a hotplug
// kanshi sometimes re-matches a profile but silently drops a
// `position X,Y` directive, leaving the live layout drifted away from
// the active profile. The GUI must (1) surface the drift via
// [KanshiController.hasLayoutDrift], (2) repair it via
// [reapplyActiveProfile] (calls `kanshictl reload`), and (3) optionally
// auto-repair when [autoReapplyOnDrift] is enabled.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kanshi_gui/models/monitor_tile_data.dart';
import 'package:kanshi_gui/models/profiles.dart';
import 'package:kanshi_gui/services/config_service.dart';
import 'package:kanshi_gui/services/kanshi_config_writer.dart';
import 'package:kanshi_gui/state/kanshi_controller.dart';

import 'fakes/fake_monitor_service.dart';
import 'fakes/fake_process_runner.dart';

MonitorTileData _mon({
  required String id,
  double x = 0,
  double y = 0,
  double w = 1920,
  double h = 1080,
  bool enabled = true,
  String? mirrorOf,
}) =>
    MonitorTileData(
      id: id,
      manufacturer: id,
      x: x,
      y: y,
      width: w,
      height: h,
      scale: 1,
      rotation: 0,
      refresh: 60,
      resolution: '${w.toInt()}x${h.toInt()}',
      orientation: 'landscape',
      enabled: enabled,
      mirrorOf: mirrorOf,
    );

ConfigService _tmpConfig(Directory dir,
        {KanshiWriteOptions writeOptions = KanshiWriteOptions.neutral}) =>
    ConfigService(
      configPath: '${dir.path}/config',
      backupPrefix: '${dir.path}/config.bak',
      writeOptions: writeOptions,
    );

void main() {
  late Directory tmp;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('kanshi_gui_drift_');
  });
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Future<KanshiController> build({
    required List<Profile> profiles,
    required List<MonitorTileData> live,
    FakeProcessRunner? runner,
    KanshiWriteOptions writeOptions = KanshiWriteOptions.neutral,
  }) async {
    final cfg = _tmpConfig(tmp, writeOptions: writeOptions);
    await cfg.saveProfiles(profiles);
    final fake = FakeMonitorService(outputs: live);
    final c = KanshiController(
      monitors: fake,
      config: cfg,
      processRunner: runner,
    );
    await c.init();
    return c;
  }

  test('no drift when live positions match the active profile', () async {
    final mons = [_mon(id: 'A'), _mon(id: 'B', x: 1920)];
    final c = await build(
      profiles: [Profile(name: 'p', monitors: mons)],
      live: mons,
    );
    expect(c.layoutDriftIssues, isEmpty);
    expect(c.hasLayoutDrift, isFalse);
  });

  test('drift surfaces when a live output is in the wrong position',
      () async {
    // Profile says B is at 1920,0 but the live layout has it offset.
    // Mirrors the kanshi-daemon position-drop race we observed in the
    // wild after re-plugging the right-hand monitor.
    final profileMons = [_mon(id: 'A'), _mon(id: 'B', x: 1920)];
    final liveMons = [_mon(id: 'A'), _mon(id: 'B', x: 6560, y: 1030)];
    final c = await build(
      profiles: [Profile(name: 'p', monitors: profileMons)],
      live: liveMons,
    );
    expect(c.hasLayoutDrift, isTrue);
    expect(c.layoutDriftIssues, hasLength(1));
    expect(c.layoutDriftIssues.first, contains('B'));
    expect(c.layoutDriftIssues.first, contains('expected'));
    expect(c.layoutDriftIssues.first, contains('1920'));
    expect(c.layoutDriftIssues.first, contains('6560'));
  });

  test('drift ignores disabled outputs', () async {
    // A disabled output has no canonical on-screen position — the live
    // coords for it are whatever the compositor parked it at and must
    // not show up in the drift list.
    final profileMons = [
      _mon(id: 'A'),
      _mon(id: 'B', x: 1920, enabled: false),
    ];
    final liveMons = [
      _mon(id: 'A'),
      _mon(id: 'B', x: 9999, enabled: false),
    ];
    final c = await build(
      profiles: [Profile(name: 'p', monitors: profileMons)],
      live: liveMons,
    );
    expect(c.hasLayoutDrift, isFalse);
  });

  test('drift ignores mirror destinations', () async {
    // A mirror destination's geometry is driven by wl-mirror, not by
    // the profile's coords — its live position is meaningless for the
    // drift check.
    final profileMons = [
      _mon(id: 'A'),
      _mon(id: 'B', x: 1920, mirrorOf: 'A'),
    ];
    final liveMons = [
      _mon(id: 'A'),
      _mon(id: 'B', x: 9999, mirrorOf: 'A'),
    ];
    final c = await build(
      profiles: [Profile(name: 'p', monitors: profileMons)],
      live: liveMons,
      // `neutral` write options drop the mirror annotation on save/load,
      // collapsing the mirror entry to a regular output and defeating
      // the test. swayDefaults round-trips it.
      writeOptions: KanshiWriteOptions.swayDefaults,
    );
    expect(c.hasLayoutDrift, isFalse);
  });

  test('sub-pixel position diffs stay within tolerance', () async {
    // Scale rounding can produce 1-px diffs that are not real drift.
    final profileMons = [_mon(id: 'A', x: 0), _mon(id: 'B', x: 1920)];
    final liveMons = [_mon(id: 'A', x: 0.4), _mon(id: 'B', x: 1921.2)];
    final c = await build(
      profiles: [Profile(name: 'p', monitors: profileMons)],
      live: liveMons,
    );
    expect(c.hasLayoutDrift, isFalse);
  });

  test('dismissDriftBanner hides the banner without applying a change',
      () async {
    final profileMons = [_mon(id: 'A'), _mon(id: 'B', x: 1920)];
    final liveMons = [_mon(id: 'A'), _mon(id: 'B', x: 6560)];
    final runner = FakeProcessRunner();
    final c = await build(
      profiles: [Profile(name: 'p', monitors: profileMons)],
      live: liveMons,
      runner: runner,
    );
    expect(c.hasLayoutDrift, isTrue);
    c.dismissDriftBanner();
    expect(c.hasLayoutDrift, isFalse);
    expect(c.layoutDriftIssues, isNotEmpty,
        reason: 'dismiss only hides the banner; the issue list is unchanged');
    expect(runner.calls, isEmpty,
        reason: 'dismiss must not run kanshictl');
  });

  test('reapplyActiveProfile runs `kanshictl reload` and refreshes outputs',
      () async {
    final profileMons = [_mon(id: 'A'), _mon(id: 'B', x: 1920)];
    final liveDrifted = [_mon(id: 'A'), _mon(id: 'B', x: 6560)];
    final runner = FakeProcessRunner();
    final c = await build(
      profiles: [Profile(name: 'p', monitors: profileMons)],
      live: liveDrifted,
      runner: runner,
    );
    // Simulate what `kanshictl reload` would achieve: by the time we
    // re-fetch outputs, positions are back to the profile's.
    (c.monitors as FakeMonitorService).outputs = profileMons;
    final res = await c.reapplyActiveProfile();
    expect(res.success, isTrue);
    expect(
      runner.calls.any(
          (inv) => inv.length >= 2 && inv[0] == 'kanshictl' && inv[1] == 'reload'),
      isTrue,
      reason: 'reapply must invoke `kanshictl reload`',
    );
    expect(c.hasLayoutDrift, isFalse,
        reason:
            'after the live layout matches the profile again, the banner is gone');
  });

  test('reapplyActiveProfile reports kanshictl failure', () async {
    final runner = FakeProcessRunner(
      responses: {
        'kanshictl reload': ProcessResult(0, 1, '', 'kanshictl: not running'),
      },
    );
    final mons = [_mon(id: 'A')];
    final c = await build(
      profiles: [Profile(name: 'p', monitors: mons)],
      live: mons,
      runner: runner,
    );
    final res = await c.reapplyActiveProfile();
    expect(res.success, isFalse);
    expect(res.message, contains('kanshictl reload failed'));
  });

  test('reapplyActiveProfile refuses to run on a non-live backend',
      () async {
    final cfg = _tmpConfig(tmp);
    await cfg.saveProfiles(
        [Profile(name: 'p', monitors: [_mon(id: 'A')])]);
    final fake = FakeMonitorService(isLive: false, outputs: [_mon(id: 'A')]);
    final runner = FakeProcessRunner();
    final c = KanshiController(
        monitors: fake, config: cfg, processRunner: runner);
    await c.init();
    final res = await c.reapplyActiveProfile();
    expect(res.success, isFalse);
    expect(runner.calls, isEmpty);
  });

  test('editing the active profile does not flap the drift banner',
      () async {
    // Regression for the "banner appears during every drag" bug: the
    // user moves a tile, which mutates the active profile's coords
    // in-memory before the compositor has caught up. Computing drift
    // live would surface a transient mismatch every pan-update; the
    // cached snapshot must only refresh on hotplug events.
    final mons = [_mon(id: 'A'), _mon(id: 'B', x: 1920)];
    final c = await build(
      profiles: [Profile(name: 'p', monitors: mons)],
      live: mons,
    );
    expect(c.layoutDriftIssues, isEmpty);
    // Mutate the profile to a position the live layout does not match
    // yet — exactly what `_onTileUpdate` does on every drag frame.
    c.updateMonitor(c.activeMonitors[1].copyWith(x: 5000));
    expect(c.layoutDriftIssues, isEmpty,
        reason:
            'profile mutations without a fresh hotplug event must not '
            'show drift');
  });

  test('hotplug clears a prior dismissal so a new drift surfaces',
      () async {
    final profileMons = [_mon(id: 'A'), _mon(id: 'B', x: 1920)];
    final liveDrifted = [_mon(id: 'A'), _mon(id: 'B', x: 6560)];
    final c = await build(
      profiles: [Profile(name: 'p', monitors: profileMons)],
      live: liveDrifted,
    );
    c.dismissDriftBanner();
    expect(c.hasLayoutDrift, isFalse);
    // Hotplug event with still-drifted layout: emit a fresh outputs list
    // so the controller's listener body runs end-to-end.
    (c.monitors as FakeMonitorService).emitOutputs(liveDrifted);
    await Future<void>.delayed(Duration.zero);
    expect(c.hasLayoutDrift, isTrue,
        reason: 'a fresh hotplug must reset the dismiss gate');
  });
}
