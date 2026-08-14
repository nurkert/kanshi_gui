import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kanshi_gui/models/monitor_tile_data.dart';
import 'package:kanshi_gui/models/profiles.dart';
import 'package:kanshi_gui/services/app_settings.dart';
import 'package:kanshi_gui/services/config_service.dart';
import 'package:kanshi_gui/services/kanshi_config_writer.dart';
import 'package:kanshi_gui/state/kanshi_controller.dart';

import 'fakes/fake_mirror_runner.dart';
import 'fakes/fake_monitor_service.dart';

/// Nine deliberate choices, one per workspace.
///
/// The rule modes answer "where should these go" with a pattern. Some desks
/// are not a pattern — a wide middle screen for the editor, the laptop for
/// chat — and before this the only way to express that was
/// [WorkspaceManagementMode.learned], which meant arranging them by hand and
/// hoping the app was watching at the right moment. This mode is the same
/// overlay with the user holding the pen.
MonitorTileData _mon(String id, double x) => MonitorTileData(
      id: id,
      manufacturer: 'Panel $id',
      edidDescriptor: 'Make $id Serial$id',
      x: x,
      y: 0,
      width: 2560,
      height: 1440,
      scale: 1.0,
      rotation: 0,
      refresh: 60,
      resolution: '2560x1440',
      orientation: 'landscape',
      enabled: true,
    );

List<MonitorTileData> desk() => [
      _mon('DP-4', 0),
      _mon('DP-5', 2560),
      _mon('eDP-1', 5120),
    ];

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('kanshi_custom_'));
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Future<KanshiController> boot(WorkspaceManagementMode mode) async {
    final cfg = ConfigService(
      configPath: '${tmp.path}/config',
      backupPrefix: '${tmp.path}/backups/config.bak',
      writeOptions: KanshiWriteOptions.swayDefaults,
    );
    await cfg.saveProfiles([Profile(name: 'Office', monitors: desk())]);
    final c = KanshiController(
      monitors: FakeMonitorService(
          outputs: desk(), writeOptions: KanshiWriteOptions.swayDefaults),
      config: cfg,
      mirrorRunner: FakeMirrorRunner(),
    )..applyStartupSettings(
        AppSettings(filePath: '${tmp.path}/settings.json')
          ..workspaceManagement = mode,
      );
    await c.init();
    return c;
  }

  group('assigning one workspace', () {
    test('moves exactly that one and switches to custom', () async {
      final c = await boot(WorkspaceManagementMode.interleaved);
      addTearDown(c.dispose);
      expect(c.currentWorkspaceMap()[7], 'DP-4');

      expect(await c.assignWorkspace(7, 'DP-5'), isTrue);

      expect(c.workspaceMode, WorkspaceManagementMode.custom);
      expect(c.currentWorkspaceMap(), {
        1: 'DP-4',
        2: 'DP-5',
        3: 'eDP-1',
        4: 'DP-4',
        5: 'DP-5',
        6: 'eDP-1',
        7: 'DP-5',
        8: 'DP-5',
        9: 'eDP-1',
      }, reason: 'the other eight are written down exactly where they were');
    });

    test('the whole arrangement lands in the config', () async {
      // The config is what kanshi replays on the next dock with the app
      // closed, so a choice that only lives in memory is not a choice.
      final c = await boot(WorkspaceManagementMode.interleaved);
      addTearDown(c.dispose);
      await c.assignWorkspace(9, 'DP-4');

      final text = File('${tmp.path}/config').readAsStringSync();
      expect(text, contains("workspace 9 output 'Make DP-4 SerialDP-4'"));
      expect(text, contains("workspace 3 output 'Make eDP-1 SerialeDP-1'"));
      expect(text, contains("# kanshi_gui:ws '9'='DP-4'"));
    });

    test('a screen this setup does not have is refused', () async {
      final c = await boot(WorkspaceManagementMode.interleaved);
      addTearDown(c.dispose);
      expect(await c.assignWorkspace(1, 'HDMI-A-9'), isFalse);
      expect(c.workspaceMode, WorkspaceManagementMode.interleaved);
    });

    test('a workspace outside 1..9 is refused', () async {
      final c = await boot(WorkspaceManagementMode.interleaved);
      addTearDown(c.dispose);
      expect(await c.assignWorkspace(10, 'DP-5'), isFalse);
      expect(await c.assignWorkspace(0, 'DP-5'), isFalse);
    });

    test('assigning where it already is changes nothing', () async {
      final c = await boot(WorkspaceManagementMode.interleaved);
      addTearDown(c.dispose);
      expect(await c.assignWorkspace(1, 'DP-4'), isFalse);
      expect(c.workspaceMode, WorkspaceManagementMode.interleaved,
          reason: 'a no-op must not silently leave a pattern behind');
    });

    test('with placement off there is nothing to assign', () async {
      final c = await boot(WorkspaceManagementMode.off);
      addTearDown(c.dispose);
      expect(await c.assignWorkspace(1, 'DP-5'), isFalse);
      expect(c.workspaceMode, WorkspaceManagementMode.off);
    });
  });

  group('custom mode', () {
    test('entering it freezes the pattern that was showing', () async {
      // Otherwise "my own" begins by resetting a grouped desk to the
      // interleaved fallback — the one moment it has no opinion is the one
      // moment it must not invent one.
      final c = await boot(WorkspaceManagementMode.grouped);
      addTearDown(c.dispose);
      final before = c.currentWorkspaceMap();
      expect(before[4], 'DP-5');

      await c.setWorkspaceMode(WorkspaceManagementMode.custom);

      expect(c.workspaceMode, WorkspaceManagementMode.custom);
      expect(c.currentWorkspaceMap(), before);
      expect(c.activeProfile?.workspaceMap, before);
    });

    test('nothing observes over it', () async {
      // The difference from `learned`, and the whole reason both exist: a
      // window opening somewhere unexpected must not rewrite nine choices.
      final fake = FakeMonitorService(
          outputs: desk(), writeOptions: KanshiWriteOptions.swayDefaults)
        ..workspaceOutputs = {1: 'eDP-1', 2: 'eDP-1'};
      final cfg = ConfigService(
        configPath: '${tmp.path}/config',
        backupPrefix: '${tmp.path}/backups/config.bak',
        writeOptions: KanshiWriteOptions.swayDefaults,
      );
      await cfg.saveProfiles([Profile(name: 'Office', monitors: desk())]);
      final c = KanshiController(
        monitors: fake,
        config: cfg,
        mirrorRunner: FakeMirrorRunner(),
      )..applyStartupSettings(
          AppSettings(filePath: '${tmp.path}/settings.json')
            ..workspaceManagement = WorkspaceManagementMode.custom,
        );
      addTearDown(c.dispose);
      await c.init();

      expect(await c.learnWorkspaceMap(), isFalse);
      expect(c.currentWorkspaceMap()[1], 'DP-4');
    });

    test('leaving it for a rule drops the map', () async {
      final c = await boot(WorkspaceManagementMode.interleaved);
      addTearDown(c.dispose);
      await c.assignWorkspace(7, 'DP-5');
      expect(c.activeProfile?.workspaceMap, isNotNull);

      await c.setWorkspaceMode(WorkspaceManagementMode.interleaved);
      expect(c.activeProfile?.workspaceMap, isNull);
      expect(c.currentWorkspaceMap()[7], 'DP-4');
    });

    test('a map made by hand survives a switch to following and back',
        () async {
      // Both modes read the same overlay, so moving between them must not
      // throw it away — what was edited is a perfectly good thing to keep
      // following, and what was learned is the obvious start for editing.
      final c = await boot(WorkspaceManagementMode.interleaved);
      addTearDown(c.dispose);
      await c.assignWorkspace(7, 'DP-5');
      final mine = c.currentWorkspaceMap();

      await c.setWorkspaceMode(WorkspaceManagementMode.learned);
      await c.setWorkspaceMode(WorkspaceManagementMode.custom);
      expect(c.currentWorkspaceMap()[7], mine[7]);
    });
  });

  group('the settings round trip', () {
    test('custom survives being written and read back', () async {
      final path = '${tmp.path}/settings.json';
      await (AppSettings(filePath: path)
            ..workspaceManagement = WorkspaceManagementMode.custom)
          .save();
      final back = await AppSettings.load(path: path);
      expect(back.workspaceManagement, WorkspaceManagementMode.custom);
      expect(back.workspaceManagement.followsMap, isTrue);
      expect(back.workspaceManagement.learns, isFalse);
    });

    test('a mode this version does not know falls back to off', () async {
      expect(WorkspaceManagementMode.fromJson('by-phase-of-moon'),
          WorkspaceManagementMode.off);
    });
  });
}
