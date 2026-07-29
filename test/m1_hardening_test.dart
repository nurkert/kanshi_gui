import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kanshi_gui/models/monitor_mode.dart';
import 'package:kanshi_gui/models/monitor_tile_data.dart';
import 'package:kanshi_gui/models/profiles.dart';
import 'package:kanshi_gui/services/config_service.dart';
import 'package:kanshi_gui/services/kanshi_config_parser.dart';
import 'package:kanshi_gui/services/kanshi_config_writer.dart';
import 'package:kanshi_gui/state/kanshi_controller.dart';
import 'package:kanshi_gui/state/safety_net.dart';

import 'fakes/fake_mirror_runner.dart';
import 'fakes/fake_monitor_service.dart';

/// Regression tests for the M1 correctness fixes in PLAN-2.0.md.
///
/// Every test here reproduces a defect that shipped in 1.6.2. They are
/// deliberately written against the behaviour a user experiences, not against
/// the implementation, so the eventual decomposition in M6 cannot quietly
/// re-introduce any of them.
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
    tmp = Directory.systemTemp.createTempSync('kanshi_gui_m1_');
  });
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Future<KanshiController> build({
    required List<Profile> profiles,
    required List<MonitorTileData> live,
    FakeMonitorService? service,
  }) async {
    final cfg = _tmpConfig(tmp);
    await cfg.saveProfiles(profiles);
    final fake = service ?? FakeMonitorService(outputs: live);
    fake.outputs = live;
    final c = KanshiController(
      monitors: fake,
      config: cfg,
      mirrorRunner: FakeMirrorRunner(),
    );
    await c.init();
    return c;
  }

  group('A1.1 — safety net switched off must not revert instantly', () {
    test('a zero window arms nothing at all', () async {
      final net = SafetyNet(window: Duration.zero);
      var reverted = false;
      var ran = false;
      await net.guard(
        key: 'k',
        label: 'k',
        doIt: () async => ran = true,
        revert: () async => reverted = true,
      );
      expect(ran, isTrue, reason: 'the operation itself must still happen');
      expect(net.activePrompt, isNull);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(reverted, isFalse,
          reason: '"Off" must mean no countdown, not an instant one');
    });

    test('applyMode with the net off keeps the new mode', () async {
      final a = _mon(id: 'A');
      final c = await build(
        profiles: [Profile(name: 'P', monitors: [a])],
        live: [a],
      );
      c.setSafetyNetSeconds(0);

      await c.applyMode(
          'A', MonitorMode(width: 1280, height: 720, refresh: 60));
      await Future<void>.delayed(const Duration(milliseconds: 80));

      final m = c.profiles.single.monitors.single;
      expect(m.width, 1280);
      expect(m.height, 720);
      c.dispose();
    });
  });

  group('A1.2 — the lockout guard counts screens the user can see', () {
    test('refuses to disable the only connected output', () async {
      // A three-output desk profile used on the train: only the laptop panel
      // is live. The guard used to count the two absent externals as "still
      // enabled" and let the one real screen be switched off.
      final laptop = _mon(id: 'eDP-1');
      final ext1 = _mon(id: 'DP-1', x: 1920);
      final ext2 = _mon(id: 'DP-2', x: 3840);
      final fake = FakeMonitorService(outputs: [laptop]);
      final c = await build(
        profiles: [
          Profile(name: 'Desk', monitors: [laptop, ext1, ext2])
        ],
        live: [laptop],
        service: fake,
      );

      final r = await c.toggleEnabled('eDP-1', false);
      expect(r.success, isFalse);
      expect(fake.calls.where((s) => s.startsWith('disable')), isEmpty,
          reason: 'the compositor must never have been asked to disable it');
      c.dispose();
    });

    test('still allows disabling when another connected output remains',
        () async {
      final a = _mon(id: 'A');
      final b = _mon(id: 'B', x: 1920);
      final fake = FakeMonitorService(outputs: [a, b]);
      final c = await build(
        profiles: [Profile(name: 'Desk', monitors: [a, b])],
        live: [a, b],
        service: fake,
      );
      fake.outputs = [a, _mon(id: 'B', x: 1920, enabled: false)];

      final r = await c.toggleEnabled('B', false);
      expect(r.success, isTrue);
      c.dispose();
    });

    test('offline editor (no live outputs) falls back to the profile count',
        () async {
      // Nothing is connected, so connectivity is unknowable. The guard must
      // not then treat every output as invisible and block all editing — it
      // falls back to counting enabled outputs in the profile.
      //
      // The two cases are told apart by which error comes back: the lockout
      // block fires before the "is this output live?" lookup, so reaching
      // the latter proves the block let the call through.
      final fake = FakeMonitorService(outputs: const [], isLive: false);
      final two = await build(
        profiles: [
          Profile(name: 'Desk', monitors: [_mon(id: 'A'), _mon(id: 'B', x: 1920)])
        ],
        live: const [],
        service: fake,
      );
      // With nothing connected, init() cannot match a profile and activates
      // an empty captured setup; select the one under test explicitly.
      two.setActiveProfile(two.profiles.indexWhere((p) => p.name == 'Desk'));
      expect((await two.toggleEnabled('A', false)).message,
          isNot(contains('last enabled output')));
      two.dispose();

      final one = await build(
        profiles: [
          Profile(name: 'Solo', monitors: [_mon(id: 'A')])
        ],
        live: const [],
        service: FakeMonitorService(outputs: const [], isLive: false),
      );
      one.setActiveProfile(one.profiles.indexWhere((p) => p.name == 'Solo'));
      expect((await one.toggleEnabled('A', false)).message,
          contains('last enabled output'));
      one.dispose();
    });
  });

  group('A1.3 — the captured setup must not alias the live snapshot', () {
    test('editing the auto-created profile leaves currentMonitors alone',
        () async {
      final live = _mon(id: 'A', w: 2560, h: 1440);
      final cfg = _tmpConfig(tmp);
      await cfg.saveProfiles([]);
      final fake = FakeMonitorService(outputs: [live]);
      final c = KanshiController(
        monitors: fake,
        config: cfg,
        mirrorRunner: FakeMirrorRunner(),
      );
      await c.init();

      expect(c.profiles.single.name, 'Setup 1');
      final beforeX = c.currentMonitors.single.x;

      c.snapAndCommit(
        c.profiles.single.monitors.single.copyWith(x: 512),
        null,
      );

      expect(c.currentMonitors.single.x, beforeX,
          reason: 'a drag in the editor must not rewrite what the app '
              'believes the compositor is doing');
      c.dispose();
    });
  });

  group('A1.4 — profile names cannot corrupt the config', () {
    test('empty and whitespace-only names are rejected', () async {
      final a = _mon(id: 'A');
      final c = await build(
        profiles: [Profile(name: 'P', monitors: [a])],
        live: [a],
      );
      expect(c.renameProfile(0, '').success, isFalse);
      expect(c.renameProfile(0, '   ').success, isFalse);
      expect(c.profiles.single.name, 'P');
      c.dispose();
    });

    test('braces and control characters are rejected', () async {
      final a = _mon(id: 'A');
      final c = await build(
        profiles: [Profile(name: 'P', monitors: [a])],
        live: [a],
      );
      expect(c.renameProfile(0, 'Desk {').success, isFalse);
      expect(c.renameProfile(0, 'Desk\nOffice').success, isFalse);
      expect(c.renameProfile(0, '# Desk').success, isFalse);
      c.dispose();
    });

    test('an apostrophe survives a round trip instead of breaking the config',
        () {
      // "Nico's Desk" used to render as `profile 'Nico's Desk' {`, which
      // kanshi refuses to parse — at which point the daemon stops managing
      // displays entirely.
      final rendered = KanshiConfigWriter.render([
        Profile(name: "Nico's Desk", monitors: [_mon(id: 'A')]),
      ]);
      expect(rendered, contains(r"profile 'Nico\'s Desk' {"));

      final reparsed = KanshiConfigParser.parse(rendered);
      expect(reparsed, hasLength(1));
      expect(reparsed.single.name, "Nico's Desk");
      expect(reparsed.single.monitors, hasLength(1));
    });

    test('a backslash survives a round trip', () {
      final rendered = KanshiConfigWriter.render([
        Profile(name: r'A\B', monitors: [_mon(id: 'A')]),
      ]);
      expect(KanshiConfigParser.parse(rendered).single.name, r'A\B');
    });
  });

  group('A2.1/A2.2 — safety-net reverts land in the right place', () {
    test('a revert survives an unrelated edit during the countdown', () async {
      // Reproduces the orphaned-list bug: every other mutation replaces the
      // Profile object, so a revert holding the old list wrote into nothing.
      // The compositor re-enabled the output while the model and the saved
      // config kept saying `disable`.
      final a = _mon(id: 'A');
      final b = _mon(id: 'B', x: 1920);
      final fake = FakeMonitorService(outputs: [a, b]);
      final c = await build(
        profiles: [Profile(name: 'Desk', monitors: [a, b])],
        live: [a, b],
        service: fake,
      );
      c.setSafetyNetSeconds(0);
      c.safetyNet.window = const Duration(milliseconds: 80);

      fake.outputs = [a, _mon(id: 'B', x: 1920, enabled: false)];
      expect((await c.toggleEnabled('B', false)).success, isTrue);
      expect(c.profiles.single.monitors[1].enabled, isFalse);

      // Any other edit — this one replaces the whole Profile object.
      c.scaleMonitor('A', 1.25, committing: true);

      fake.outputs = [a, b];
      await Future<void>.delayed(const Duration(milliseconds: 220));

      expect(c.profiles.single.monitors.firstWhere((m) => m.id == 'B').enabled,
          isTrue,
          reason: 'the model must agree with the compositor after a revert');
      c.dispose();
    });

    test('a revert restores the profile it belonged to, not the active one',
        () async {
      final a = _mon(id: 'A');
      final b = _mon(id: 'B', x: 1920);
      final fake = FakeMonitorService(outputs: [a, b]);
      final c = await build(
        profiles: [
          Profile(name: 'Desk', monitors: [a, b]),
          Profile(name: 'Other', monitors: [_mon(id: 'A'), _mon(id: 'B', x: 1920)]),
        ],
        live: [a, b],
        service: fake,
      );
      final deskIdx = c.profiles.indexWhere((p) => p.name == 'Desk');
      c.setActiveProfile(deskIdx);
      c.safetyNet.window = const Duration(milliseconds: 80);

      fake.outputs = [a, _mon(id: 'B', x: 1920, enabled: false)];
      expect((await c.toggleEnabled('B', false)).success, isTrue);

      // The user switches profiles while the countdown runs.
      c.setActiveProfile(c.profiles.indexWhere((p) => p.name == 'Other'));

      fake.outputs = [a, b];
      await Future<void>.delayed(const Duration(milliseconds: 220));

      final desk = c.profiles.firstWhere((p) => p.name == 'Desk');
      expect(desk.monitors.firstWhere((m) => m.id == 'B').enabled, isTrue,
          reason: 'the guarded profile is the one that must be repaired');
      c.dispose();
    });
  });

  group('A2.3 — a failing revert is reported and retryable', () {
    test('the failure surfaces instead of becoming an unhandled error',
        () async {
      final net = SafetyNet(window: const Duration(milliseconds: 60));
      Object? seen;
      net.onRevertFailed = (_, __, e) => seen = e;
      var attempts = 0;
      await net.guard(
        key: 'k',
        label: 'Disabled DP-1',
        doIt: () async {},
        revert: () async {
          attempts++;
          throw StateError('compositor said no');
        },
      );

      await Future<void>.delayed(const Duration(milliseconds: 160));
      expect(seen, isA<StateError>());
      expect(net.hasFailedRevert, isTrue);
      expect(net.failedRevertLabels, ['Disabled DP-1']);
      expect(attempts, 1);
    });

    test('retry re-runs the inverse and clears once it works', () async {
      final net = SafetyNet(window: const Duration(milliseconds: 60));
      var failNext = true;
      await net.guard(
        key: 'k',
        label: 'Disabled DP-1',
        doIt: () async {},
        revert: () async {
          if (failNext) throw StateError('nope');
        },
      );
      await Future<void>.delayed(const Duration(milliseconds: 160));
      expect(net.hasFailedRevert, isTrue);

      var stillFailing = await net.retryFailedReverts();
      expect(stillFailing, ['Disabled DP-1']);
      expect(net.hasFailedRevert, isTrue);

      failNext = false;
      stillFailing = await net.retryFailedReverts();
      expect(stillFailing, isEmpty);
      expect(net.hasFailedRevert, isFalse);
    });
  });
}
