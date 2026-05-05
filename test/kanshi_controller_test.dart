import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kanshi_gui/models/monitor_mode.dart';
import 'package:kanshi_gui/models/monitor_tile_data.dart';
import 'package:kanshi_gui/models/profiles.dart';
import 'package:kanshi_gui/services/config_service.dart';
import 'package:kanshi_gui/services/kanshi_config_writer.dart';
import 'package:kanshi_gui/state/kanshi_controller.dart';

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
      backupPath: '${dir.path}/config.bak',
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

  test('controller propagates writeOptions from backend to ConfigService', () {
    final fake = FakeMonitorService(
        writeOptions: KanshiWriteOptions.neutral);
    // Start with sway defaults — the controller must override to neutral
    // because the active backend is wlr-randr-style.
    final cfg = ConfigService(
      configPath: '${tmp.path}/c',
      backupPath: '${tmp.path}/c.bak',
      writeOptions: KanshiWriteOptions.swayDefaults,
    );
    KanshiController(monitors: fake, config: cfg);
    expect(cfg.writeOptions.injectSwayWorkspaceExec, isFalse);
  });
}
