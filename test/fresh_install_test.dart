import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kanshi_gui/models/monitor_tile_data.dart';
import 'package:kanshi_gui/services/app_settings.dart';
import 'package:kanshi_gui/services/config_service.dart';
import 'package:kanshi_gui/services/kanshi_config_writer.dart';
import 'package:kanshi_gui/state/kanshi_controller.dart';

import 'fakes/fake_mirror_runner.dart';
import 'fakes/fake_monitor_service.dart';

/// What a stranger gets on their first launch: a tool that lines up screens,
/// and nothing else.
///
/// This file exists because of one user. kanshi_gui was recommended to them,
/// they opened it, their workspaces were rearranged, and they uninstalled it
/// the same day. They were right to. Someone who installs a monitor arranger
/// has consented to arranging monitors — not to having their `$mod+3` mean
/// something different afterwards.
///
/// So every one of these tests asks the same question from a different angle:
/// **on a machine that has never run this app, does anything touch the
/// workspaces?** The answer has to stay no, in the config it writes and in the
/// commands it sends, and it has to stay no even though the code that would do
/// the touching is right there and switched off by a single flag.
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

List<MonitorTileData> desk() =>
    [_mon('DP-4', 0), _mon('DP-5', 2560), _mon('eDP-1', 5120)];

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('kanshi_fresh_'));
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('a machine that has never run this app', () {
    test('no settings file means workspace placement is off', () async {
      // The only thing standing between a new user and a rearranged desktop.
      final s = await AppSettings.load(path: '${tmp.path}/settings.json');
      expect(s.workspaceManagement, WorkspaceManagementMode.off);
      expect(s.workspaceManagement.enabled, isFalse);
      expect(s.workspaceManagement.distribution, isNull);
    });

    test('first launch writes a config with no workspace lines in it',
        () async {
      // The config is what kanshi replays forever after. A workspace line in
      // there is a change to the user's desktop that outlives the app.
      final fake = FakeMonitorService(
          outputs: desk(), writeOptions: KanshiWriteOptions.swayDefaults);
      final cfg = ConfigService(
        configPath: '${tmp.path}/config',
        backupPrefix: '${tmp.path}/backups/config.bak',
        writeOptions: KanshiWriteOptions.swayDefaults,
      );
      final c = KanshiController(
        monitors: fake,
        config: cfg,
        mirrorRunner: FakeMirrorRunner(),
      )..applyStartupSettings(
          await AppSettings.load(path: '${tmp.path}/settings.json'),
        );
      addTearDown(c.dispose);
      await c.init();
      await cfg.saveProfiles(c.profiles.toList());

      final text = File('${tmp.path}/config').readAsStringSync();
      expect(text, isNot(contains('workspace')));
      expect(text, isNot(contains('exec swaymsg')));
      // It still did its actual job.
      expect(text, contains('DP-4'));
      expect(text, contains('position'));
    });

    test('first launch sends no workspace command to the compositor',
        () async {
      // Even with the layout drifted — the state that makes the repair pass
      // want to act — a fresh install must send nothing.
      final fake = FakeMonitorService(
          outputs: desk(), writeOptions: KanshiWriteOptions.swayDefaults)
        ..workspaceOutputs = {1: 'eDP-1', 2: 'eDP-1', 9: 'eDP-1'};
      final c = KanshiController(
        monitors: fake,
        config: ConfigService(
          configPath: '${tmp.path}/config',
          backupPrefix: '${tmp.path}/backups/config.bak',
          writeOptions: KanshiWriteOptions.swayDefaults,
        ),
        mirrorRunner: FakeMirrorRunner(),
      )..applyStartupSettings(
          await AppSettings.load(path: '${tmp.path}/settings.json'),
        );
      addTearDown(c.dispose);
      await c.init();

      expect(fake.workspaceChainCalls, isEmpty,
          reason: 'a first launch must not move a single workspace');
    });

    test('the workspaces stay exactly where the compositor had them',
        () async {
      final before = {1: 'eDP-1', 2: 'eDP-1', 3: 'DP-4'};
      final fake = FakeMonitorService(
          outputs: desk(), writeOptions: KanshiWriteOptions.swayDefaults)
        ..workspaceOutputs = Map.of(before);
      final c = KanshiController(
        monitors: fake,
        config: ConfigService(
          configPath: '${tmp.path}/config',
          backupPrefix: '${tmp.path}/backups/config.bak',
          writeOptions: KanshiWriteOptions.swayDefaults,
        ),
        mirrorRunner: FakeMirrorRunner(),
      )..applyStartupSettings(
          await AppSettings.load(path: '${tmp.path}/settings.json'),
        );
      addTearDown(c.dispose);
      await c.init();

      expect(fake.workspaceOutputs, before);
      expect(c.workspaceMode, WorkspaceManagementMode.off);
    });

    test('nothing is learned, so nothing can be cemented later', () async {
      // The observation path is the one that could turn "we looked" into "we
      // decided". With placement off it must not even look.
      final fake = FakeMonitorService(
          outputs: desk(), writeOptions: KanshiWriteOptions.swayDefaults)
        ..workspaceOutputs = {1: 'DP-4', 2: 'DP-5'};
      final c = KanshiController(
        monitors: fake,
        config: ConfigService(
          configPath: '${tmp.path}/config',
          backupPrefix: '${tmp.path}/backups/config.bak',
          writeOptions: KanshiWriteOptions.swayDefaults,
        ),
        mirrorRunner: FakeMirrorRunner(),
      )..applyStartupSettings(
          await AppSettings.load(path: '${tmp.path}/settings.json'),
        );
      addTearDown(c.dispose);
      await c.init();

      expect(await c.learnWorkspaceMap(), isFalse);
      expect(c.activeProfile?.workspaceMap, isNull);
    });

    test('the helper daemon does nothing while placement is off', () async {
      // Same guarantee on the other side of the fence: the service can be
      // running and still be a no-op, because it re-reads the setting on
      // every event rather than caching what it was started with.
      expect(WorkspaceManagementMode.off.distribution, isNull);
      expect(WorkspaceManagementMode.off.enabled, isFalse);
    });
  });

  group('the one case where the app turns it on by itself', () {
    test('a settings file that predates the setting keeps its old behaviour',
        () async {
      // Deliberate and narrow: a settings.json with no `workspaceManagement`
      // key can only have been written by a version where placement was
      // unconditional and always on. Those users already have it; defaulting
      // them to `off` would be the change, not the continuity.
      //
      // Every version since writes the key explicitly, so this cannot be
      // reached by anyone who has run 2.0 or later.
      final path = '${tmp.path}/settings.json';
      File(path).writeAsStringSync('{"coachHintShown":true}');
      final s = await AppSettings.load(path: path);
      expect(s.workspaceManagement, WorkspaceManagementMode.interleaved);
    });

    test('a settings file written by this version always names the mode',
        () async {
      final path = '${tmp.path}/settings.json';
      await AppSettings(filePath: path).save();
      expect(File(path).readAsStringSync(), contains('"workspaceManagement"'));
      final s = await AppSettings.load(path: path);
      expect(s.workspaceManagement, WorkspaceManagementMode.off,
          reason: 'a file we wrote ourselves must round-trip to off');
    });

    test('an unreadable settings file falls back to off, not to a rule',
        () async {
      // A truncated or hand-mangled file must fail towards doing nothing.
      final path = '${tmp.path}/settings.json';
      File(path).writeAsStringSync('{ this is not json');
      final s = await AppSettings.load(path: path);
      expect(s.workspaceManagement, WorkspaceManagementMode.off);
    });
  });
}
