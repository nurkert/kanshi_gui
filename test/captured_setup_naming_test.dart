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

/// Arriving somewhere unknown must still leave you with something to edit.
///
/// The app captures the connected screens as a profile whenever none of the
/// saved ones fit, so there is always an active setup to drag. That capture
/// used to be called "Current Setup" and was reused by name, which had two
/// consequences: a second desk overwrote the first desk's capture, and
/// pressing "remember these screens" twice produced two profiles with
/// identical names. Names are the key the config file is edited by, so two
/// profiles sharing one is not cosmetic — they collapse onto a single block
/// when saved.
MonitorTileData _mon({
  required String id,
  double x = 0,
  double y = 0,
  double w = 1920,
  double h = 1080,
}) =>
    MonitorTileData(
      id: id,
      manufacturer: id,
      edidDescriptor: 'Make $id Serial$id',
      x: x,
      y: y,
      width: w,
      height: h,
      scale: 1.0,
      rotation: 0,
      refresh: 60,
      resolution: '${w.toInt()}x${h.toInt()}',
      orientation: 'landscape',
      enabled: true,
    );

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('kanshi_capture_'));
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  ConfigService cfg() => ConfigService(
        configPath: '${tmp.path}/config',
        backupPrefix: '${tmp.path}/backups/config.bak',
        writeOptions: KanshiWriteOptions.neutral,
      );

  Future<KanshiController> boot(FakeMonitorService fake, ConfigService c) async {
    final ctl = KanshiController(
        monitors: fake, config: c, mirrorRunner: FakeMirrorRunner());
    await ctl.init();
    return ctl;
  }

  test('an empty config still yields an editable setup', () async {
    // The case the user hit: no profile left at all. Without a capture there
    // is no active profile, the canvas has nothing to draw and every edit is
    // a no-op — the app is open but inert.
    final c = await boot(FakeMonitorService(outputs: [_mon(id: 'A')]), cfg());
    addTearDown(c.dispose);

    expect(c.activeProfile, isNotNull);
    expect(c.activeProfile!.name, 'Setup 1');
    expect(c.activeMonitors, hasLength(1));
  });

  test('the number skips names already taken', () async {
    final config = cfg();
    await config.saveProfiles([
      Profile(name: 'Setup 1', monitors: [_mon(id: 'X')]),
      Profile(name: 'Setup 3', monitors: [_mon(id: 'Y')]),
    ]);
    final c = await boot(FakeMonitorService(outputs: [_mon(id: 'A')]), config);
    addTearDown(c.dispose);

    expect(c.activeProfile!.name, 'Setup 2',
        reason: 'the lowest free number, not one past the count');
  });

  test('a second desk does not overwrite the first desk\'s capture', () async {
    // The regression that made reuse-by-name unsafe: arrange desk A, walk to
    // desk B, and desk A's arrangement was silently overwritten because both
    // captures answered to the same name.
    final config = cfg();
    final first = await boot(
        FakeMonitorService(
            outputs: [_mon(id: 'A'), _mon(id: 'A2', x: 1920)]),
        config);
    expect(first.activeProfile!.name, 'Setup 1');
    // The user arranges it: A2 goes below A rather than beside it. A lone
    // monitor would just snap back to the origin, so the second screen is
    // what makes the arrangement observable at all.
    final a2 = first.activeMonitors.firstWhere((m) => m.id == 'A2');
    first.snapAndCommit(a2.copyWith(x: 0, y: 1080), a2);
    await Future<void>.delayed(const Duration(milliseconds: 900));
    final arranged = {
      for (final m in first.activeProfile!.monitors) m.id: Offset(m.x, m.y),
    };
    first.dispose();

    // A different desk, a later launch, still nothing that matches.
    final second = await boot(
        FakeMonitorService(outputs: [_mon(id: 'B'), _mon(id: 'C', x: 1920)]),
        cfg());
    addTearDown(second.dispose);

    expect(second.activeProfile!.name, 'Setup 2');
    final one = second.profiles.firstWhere((p) => p.name == 'Setup 1');
    expect({for (final m in one.monitors) m.id: Offset(m.x, m.y)}, arranged,
        reason: 'the arrangement made at the first desk must survive intact');
  });

  test('an untouched capture follows a hotplug instead of multiplying',
      () async {
    // Before the user has edited anything the capture is still scratch, so
    // plugging a screen in re-points it rather than adding a setup they never
    // asked for — and, more importantly, rather than leaving them editing an
    // arrangement that is no longer in front of them.
    final config = cfg();
    final fake = FakeMonitorService(outputs: [_mon(id: 'A')]);
    final c = await boot(fake, config);
    addTearDown(c.dispose);
    c.hotplugSettleWindow = const Duration(milliseconds: 20);

    fake.emitOutputs([_mon(id: 'A'), _mon(id: 'B', x: 1920)]);
    await Future<void>.delayed(const Duration(milliseconds: 300));

    expect(c.profiles.map((p) => p.name), ['Setup 1']);
    expect(c.activeMonitors.map((m) => m.id), containsAll(['A', 'B']));
  });

  test('a hotplug never yanks the user out of a setup they chose', () async {
    final config = cfg();
    await config.saveProfiles([
      Profile(name: 'Home Office', monitors: [_mon(id: 'X')]),
    ]);
    final fake = FakeMonitorService(outputs: [_mon(id: 'A')]);
    final c = await boot(fake, config);
    addTearDown(c.dispose);
    c.hotplugSettleWindow = const Duration(milliseconds: 20);

    // The user deliberately opens a setup for hardware that is elsewhere.
    c.setActiveProfile(c.profiles.indexWhere((p) => p.name == 'Home Office'));
    fake.emitOutputs([_mon(id: 'A'), _mon(id: 'B', x: 1920)]);
    await Future<void>.delayed(const Duration(milliseconds: 300));

    expect(c.activeProfile!.name, 'Home Office',
        reason: 'a capture must never take over a deliberate selection');
  });

  test('remembering the current screens twice does not duplicate a name',
      () async {
    final config = cfg();
    final fake = FakeMonitorService(outputs: [_mon(id: 'A')]);
    final c = await boot(fake, config);
    addTearDown(c.dispose);

    c.createProfileFromCurrentSetup();
    c.createProfileFromCurrentSetup();

    final names = c.profiles.map((p) => p.name).toList();
    expect(names.toSet(), hasLength(names.length),
        reason: 'two profiles sharing a name collapse into one on save');
  });

  test('the capture reaches the config once the user edits it', () async {
    final config = cfg();
    final fake = FakeMonitorService(outputs: [_mon(id: 'A')]);
    final c = await boot(fake, config);
    addTearDown(c.dispose);

    // init() deliberately does NOT write: opening the app must not rewrite a
    // working config. The first real edit is what persists it.
    final a = c.activeMonitors.single;
    c.snapAndCommit(a.copyWith(x: 250), a);
    await Future<void>.delayed(const Duration(milliseconds: 900));

    final onDisk =
        KanshiConfigParser.parse(File('${tmp.path}/config').readAsStringSync());
    expect(onDisk.map((p) => p.name), contains('Setup 1'));
  });
}
