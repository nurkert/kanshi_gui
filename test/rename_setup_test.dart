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

/// Renaming a setup.
///
/// `renameProfile` existed on the controller for a long time with no caller:
/// M8 deleted the profile rail that used to reach it and the replacement
/// popover only offered "select" and "forget". A capture is called `Setup 3`
/// until the user says otherwise, so being unable to say otherwise is not a
/// small gap — and the rename has to survive the trip through the config
/// file, which addresses profiles BY NAME and therefore treats a rename as a
/// removal plus an append.
MonitorTileData _mon({required String id, double x = 0}) => MonitorTileData(
      id: id,
      manufacturer: id,
      edidDescriptor: 'Make $id Serial$id',
      x: x,
      y: 0,
      width: 1920,
      height: 1080,
      scale: 1.0,
      rotation: 0,
      refresh: 60,
      resolution: '1920x1080',
      orientation: 'landscape',
      enabled: true,
    );

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('kanshi_rename_'));
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  ConfigService cfg() => ConfigService(
        configPath: '${tmp.path}/config',
        backupPrefix: '${tmp.path}/backups/config.bak',
        writeOptions: KanshiWriteOptions.neutral,
      );

  Future<KanshiController> boot(ConfigService config, List<String> ids) async {
    final c = KanshiController(
      monitors: FakeMonitorService(outputs: [
        for (var i = 0; i < ids.length; i++)
          _mon(id: ids[i], x: i * 1920.0),
      ]),
      config: config,
      mirrorRunner: FakeMirrorRunner(),
    );
    await c.init();
    return c;
  }

  String onDisk() => File('${tmp.path}/config').readAsStringSync();

  test('the new name reaches the config and the old one is gone', () async {
    final config = cfg();
    await config.saveProfiles([
      Profile(name: 'Current Setup', monitors: [_mon(id: 'A')]),
    ]);
    final c = await boot(config, ['A']);
    addTearDown(c.dispose);

    final idx = c.profiles.indexWhere((p) => p.name == 'Current Setup');
    final r = c.renameProfile(idx, 'Home Office');
    expect(r.success, isTrue, reason: r.message);
    await Future<void>.delayed(const Duration(milliseconds: 900));

    final names = KanshiConfigParser.parse(onDisk()).map((p) => p.name);
    expect(names, contains('Home Office'));
    expect(names, isNot(contains('Current Setup')));
  });

  test('the arrangement is not disturbed by the rename', () async {
    final config = cfg();
    await config.saveProfiles([
      Profile(name: 'Setup 1', monitors: [
        _mon(id: 'A'),
        _mon(id: 'B', x: 1920),
      ]),
    ]);
    final c = await boot(config, ['A', 'B']);
    addTearDown(c.dispose);
    final before = {
      for (final m in c.profiles.single.monitors) m.id: '${m.x},${m.y}',
    };

    expect(c.renameProfile(0, 'Desk').success, isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 900));

    final after = KanshiConfigParser.parse(onDisk()).single;
    expect(after.name, 'Desk');
    expect({for (final m in after.monitors) m.id: '${m.x},${m.y}'}, before);
  });

  test('other profiles are untouched', () async {
    final config = cfg();
    await config.saveProfiles([
      Profile(name: 'Keep me', monitors: [_mon(id: 'X')]),
      Profile(name: 'Setup 1', monitors: [_mon(id: 'A')]),
      Profile(name: 'Keep me too', monitors: [_mon(id: 'Y')]),
    ]);
    final c = await boot(config, ['A']);
    addTearDown(c.dispose);

    expect(c.renameProfile(c.profiles.indexWhere((p) => p.name == 'Setup 1'),
            'Renamed').success,
        isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 900));

    final names = KanshiConfigParser.parse(onDisk()).map((p) => p.name);
    expect(names, containsAll(['Keep me', 'Keep me too', 'Renamed']));
    expect(names, isNot(contains('Setup 1')));
  });

  test('a duplicate name is refused rather than merged', () async {
    // Two profiles sharing a name collapse onto one block on save, because
    // the config is edited by name. Refusing is the only safe answer.
    final config = cfg();
    await config.saveProfiles([
      Profile(name: 'Desk', monitors: [_mon(id: 'X')]),
      Profile(name: 'Setup 1', monitors: [_mon(id: 'A')]),
    ]);
    final c = await boot(config, ['A']);
    addTearDown(c.dispose);

    final r = c.renameProfile(
        c.profiles.indexWhere((p) => p.name == 'Setup 1'), 'desk');
    expect(r.success, isFalse,
        reason: 'a case-different duplicate is still a duplicate');
    expect(c.profiles.map((p) => p.name), containsAll(['Desk', 'Setup 1']));
  });

  test('an unusable name is refused before it reaches the file', () {
    // `profile '' {` and a name carrying a brace both produce a config kanshi
    // refuses, at which point the daemon stops managing displays at all.
    expect(KanshiController.profileNameError(''), isNotNull);
    expect(KanshiController.profileNameError('   '), isNotNull);
    expect(KanshiController.profileNameError('a{b'), isNotNull);
    expect(KanshiController.profileNameError('#comment'), isNotNull);
    expect(KanshiController.profileNameError('line\nbreak'), isNotNull);
    expect(KanshiController.profileNameError("Nico's Desk"), isNull,
        reason: 'an apostrophe is escaped by the writer, not rejected');
  });

  test('a renamed setup still matches the screens it describes', () async {
    // The rename must not cost the profile its identity: it is matched by the
    // displays it lists, and the name is only a label.
    final config = cfg();
    await config.saveProfiles([
      Profile(name: 'Setup 1', monitors: [_mon(id: 'A'), _mon(id: 'B', x: 1920)]),
    ]);
    final c = await boot(config, ['A', 'B']);
    addTearDown(c.dispose);
    expect(c.activeProfile!.name, 'Setup 1');

    expect(c.renameProfile(0, 'Desk').success, isTrue);
    expect(c.activeProfile!.name, 'Desk',
        reason: 'the renamed profile is still the active one');
    expect(c.profileMatchInfo(0).status, ProfileMatchStatus.full);
  });

  test('a rename is undoable', () async {
    final config = cfg();
    await config.saveProfiles([
      Profile(name: 'Setup 1', monitors: [_mon(id: 'A')]),
    ]);
    final c = await boot(config, ['A']);
    addTearDown(c.dispose);

    expect(c.renameProfile(0, 'Typo').success, isTrue);
    await c.undo();
    expect(c.profiles.single.name, 'Setup 1');
  });
}
