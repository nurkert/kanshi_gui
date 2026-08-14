import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kanshi_gui/models/monitor_tile_data.dart';
import 'package:kanshi_gui/models/profiles.dart';
import 'package:kanshi_gui/services/app_settings.dart';
import 'package:kanshi_gui/services/config_service.dart';
import 'package:kanshi_gui/services/kanshi_config_writer.dart';
import 'package:kanshi_gui/state/kanshi_controller.dart';
import 'package:kanshi_gui/state/workspace_placement.dart';

import 'fakes/fake_mirror_runner.dart';
import 'fakes/fake_monitor_service.dart';

/// Every numeric workspace has a home, on every setup, always.
///
/// The bug this pins down: since M9 a setup that had ever been observed used
/// its own `workspaceMap` INSTEAD of the distribution rule. But sway only
/// reports the workspaces that currently exist — it does not pre-create empty
/// ones — so what got learned was whatever happened to be open. A three-screen
/// desk with workspaces 1, 2, 3 up learned exactly those three, and 4..9 were
/// left with no `workspace N output X` line anywhere in the config. sway puts
/// an unbound workspace on the focused output, so $mod+9 landed wherever the
/// cursor was, and the next observation wrote that accident down as a
/// preference.
///
/// The rule now covers 1..9 unconditionally and an observation only overlays
/// it. A hole is no longer expressible.
MonitorTileData _mon(String id, double x, {String? edid}) => MonitorTileData(
      id: id,
      manufacturer: id,
      edidDescriptor: edid ?? '',
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

/// The reporter's actual desk, left to right: two 27" panels and the laptop.
List<MonitorTileData> desk() => [
      _mon('DP-4', 8072),
      _mon('DP-5', 10632),
      _mon('eDP-1', 13192),
    ];

/// Which workspace numbers the chain sends to [output], read back out of the
/// emitted swaymsg text rather than out of the map that produced it.
List<int> _workspacesOn(String chain, String output) {
  final found = <int>[];
  for (final part in chain.split('; ')) {
    final m = RegExp(r"^workspace (\d+) output '(.+)'$").firstMatch(part);
    if (m != null && m.group(2) == output) found.add(int.parse(m.group(1)!));
  }
  return found..sort();
}

void main() {
  group('the rule covers every workspace', () {
    test('three screens get 1 4 7, 2 5 8, 3 6 9', () {
      final chain = buildSwayWorkspaceChain(resolveWorkspaceRanks(desk()))!;
      expect(_workspacesOn(chain, 'DP-4'), [1, 4, 7]);
      expect(_workspacesOn(chain, 'DP-5'), [2, 5, 8]);
      expect(_workspacesOn(chain, 'eDP-1'), [3, 6, 9],
          reason: r'$mod+9 has to reach the third screen');
    });

    test('a partial observation cannot leave a workspace homeless', () {
      // Exactly what was in the reporter's config: the three workspaces that
      // were open, plus one stray. Five of the nine had no home at all.
      final chain = buildSwayWorkspaceChain(
        resolveWorkspaceRanks(desk()),
        learned: {1: 'DP-4', 2: 'DP-5', 3: 'eDP-1', 8: 'eDP-1'},
      )!;
      final homed = {
        for (final o in ['DP-4', 'DP-5', 'eDP-1']) ..._workspacesOn(chain, o),
      };
      expect(homed, {1, 2, 3, 4, 5, 6, 7, 8, 9});
    });

    test('the rule alone ignores a stray observation', () {
      // Workspace 8 on the laptop was not a choice — it is where an unbound
      // workspace opened because the cursor was there. Without `learned` the
      // rule decides, and 8 belongs to the middle screen.
      final chain = buildSwayWorkspaceChain(resolveWorkspaceRanks(desk()))!;
      expect(_workspacesOn(chain, 'DP-5'), contains(8));
      expect(_workspacesOn(chain, 'eDP-1'), isNot(contains(8)));
    });

    test('an observation overlays the rule where it is followed', () {
      final chain = buildSwayWorkspaceChain(
        resolveWorkspaceRanks(desk()),
        learned: {8: 'eDP-1'},
      )!;
      expect(_workspacesOn(chain, 'eDP-1'), [3, 6, 8, 9]);
      expect(_workspacesOn(chain, 'DP-5'), [2, 5]);
    });

    test('an observation naming a screen this setup lacks is dropped', () {
      // A screen mid-unplug, or another setup's leftovers. sway silently
      // ignores an `output` target it cannot resolve, which would put the
      // workspace straight back in the homeless state.
      final chain = buildSwayWorkspaceChain(
        resolveWorkspaceRanks(desk()),
        learned: {5: 'HDMI-A-9'},
      )!;
      expect(_workspacesOn(chain, 'DP-5'), contains(5));
    });

    test('an out-of-range observation is dropped', () {
      final map = resolveWorkspaceMap(
        resolveWorkspaceRanks(desk()),
        learned: {0: 'DP-4', 10: 'DP-4', 42: 'eDP-1'},
      );
      expect(map.keys.toList()..sort(), [1, 2, 3, 4, 5, 6, 7, 8, 9]);
    });

    test('grouped gives each screen a contiguous band', () {
      final chain = buildSwayWorkspaceChain(
        resolveWorkspaceRanks(desk()),
        distribution: WorkspaceDistribution.grouped,
      )!;
      expect(_workspacesOn(chain, 'DP-4'), [1, 2, 3]);
      expect(_workspacesOn(chain, 'DP-5'), [4, 5, 6]);
      expect(_workspacesOn(chain, 'eDP-1'), [7, 8, 9]);
    });

    test('a home is declared before anything is moved into it', () {
      final chain = buildSwayWorkspaceChain(resolveWorkspaceRanks(desk()))!;
      expect(chain.indexOf("workspace 9 output 'eDP-1'"),
          lessThan(chain.indexOf('workspace number 9')));
      expect(chain, endsWith('workspace number 1'));
    });

    test('the repair pass expects the same nine homes it writes', () {
      final want = WorkspacePlacement.expectedMapping(
        resolveWorkspaceRanks(desk()),
        WorkspaceDistribution.interleaved,
      );
      expect(want.length, 9);
      expect(want[9], 'eDP-1');
      // A live workspace 9 sitting on the wrong screen is a mismatch the
      // repair pass has to notice; before, `want` had no 9 to compare to.
      expect(WorkspacePlacement.needsRepair(want, {9: 'DP-4'}), isTrue);
    });
  });

  group('what the user chose is what the config says', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('kanshi_grid_'));
    tearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    ConfigService cfg(KanshiWriteOptions o) => ConfigService(
          configPath: '${tmp.path}/config',
          backupPrefix: '${tmp.path}/backups/config.bak',
          writeOptions: o,
        );

    Profile stale() => Profile(
          name: 'Office',
          monitors: desk(),
          workspaceMap: {1: 'DP-4', 2: 'DP-5', 3: 'eDP-1', 8: 'eDP-1'},
        );

    test('a rule mode writes nine bindings and drops the stale annotations',
        () async {
      final c = cfg(KanshiWriteOptions.swayDefaults);
      await c.saveProfiles([stale()]);
      final text = File('${tmp.path}/config').readAsStringSync();

      for (var ws = 1; ws <= 9; ws++) {
        expect(text, contains('workspace $ws output '),
            reason: 'workspace $ws would open under the cursor');
      }
      expect(text, contains("workspace 8 output 'DP-5'"));
      expect(text, isNot(contains('kanshi_gui:ws')),
          reason: 'an annotation the chain contradicts is a lie in the file');
    });

    test('following the user keeps their map, and still fills the gaps',
        () async {
      final c = cfg(KanshiWriteOptions.swayDefaults
          .copyWith(followProfileWorkspaceMap: true));
      await c.saveProfiles([stale()]);
      final text = File('${tmp.path}/config').readAsStringSync();

      expect(text, contains("workspace 8 output 'eDP-1'"));
      expect(text, contains("workspace 5 output 'DP-5'"),
          reason: 'a workspace they never opened still needs a home');
      expect(text, contains("# kanshi_gui:ws '8'='eDP-1'"));
    });
  });

  group('learning is a choice, not a default', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('kanshi_learn_'));
    tearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    Future<KanshiController> boot({required bool follow}) async {
      final config = ConfigService(
        configPath: '${tmp.path}/config',
        backupPrefix: '${tmp.path}/backups/config.bak',
        writeOptions: KanshiWriteOptions.swayDefaults,
      );
      await config.saveProfiles([Profile(name: 'Office', monitors: desk())]);
      final fake = FakeMonitorService(
          outputs: desk(), writeOptions: KanshiWriteOptions.swayDefaults)
        ..workspaceOutputs = {1: 'DP-4', 2: 'DP-5', 3: 'eDP-1', 6: 'eDP-1'};
      final c = KanshiController(
        monitors: fake,
        config: config,
        mirrorRunner: FakeMirrorRunner(),
        workspaceDistribution: WorkspaceDistribution.interleaved,
        followProfileWorkspaceMap: follow,
        learnWorkspaceMapFromLive: follow,
      );
      await c.init();
      return c;
    }

    test('a rule mode records nothing', () async {
      // Otherwise the feedback loop closes: a workspace with no binding opens
      // under the cursor, and the observation cements that as a preference.
      final c = await boot(follow: false);
      addTearDown(c.dispose);
      expect(c.activeProfile?.workspaceMap, isNull);
      expect(await c.learnWorkspaceMap(), isFalse);
    });

    test('the following mode records what it sees', () async {
      final c = await boot(follow: true);
      addTearDown(c.dispose);
      expect(c.activeProfile?.workspaceMap,
          {1: 'DP-4', 2: 'DP-5', 3: 'eDP-1', 6: 'eDP-1'});
    });

    test('leaving the following mode forgets the map', () async {
      final c = await boot(follow: true);
      addTearDown(c.dispose);
      expect(c.activeProfile?.workspaceMap, isNotNull);

      await c.setWorkspaceMode(WorkspaceManagementMode.interleaved);
      expect(c.activeProfile?.workspaceMap, isNull,
          reason: 'a stale observation must not outlive the mode that made it');
      expect(c.workspaceMode, WorkspaceManagementMode.interleaved);
    });

    test('the settings file is what switches it on, the way the app does',
        () async {
      // main.dart configures the controller ONLY through applyStartupSettings.
      // The constructor argument every test above uses has no production
      // caller, so a mode that works there and not here works nowhere.
      final config = ConfigService(
        configPath: '${tmp.path}/config',
        backupPrefix: '${tmp.path}/backups/config.bak',
        writeOptions: KanshiWriteOptions.swayDefaults,
      );
      await config.saveProfiles([Profile(name: 'Office', monitors: desk())]);
      final settings = AppSettings(filePath: '${tmp.path}/settings.json')
        ..workspaceManagement = WorkspaceManagementMode.learned;
      final c = KanshiController(
        monitors: FakeMonitorService(
            outputs: desk(), writeOptions: KanshiWriteOptions.swayDefaults)
          ..workspaceOutputs = {1: 'DP-4', 2: 'eDP-1'},
        config: config,
        mirrorRunner: FakeMirrorRunner(),
      )..applyStartupSettings(settings);
      addTearDown(c.dispose);
      await c.init();

      expect(c.workspaceMode, WorkspaceManagementMode.learned);
      expect(c.config.writeOptions.followProfileWorkspaceMap, isTrue);
      expect(c.activeProfile?.workspaceMap, {1: 'DP-4', 2: 'eDP-1'});
    });

    test('the mode the controller reports is the one it is running', () async {
      final c = await boot(follow: false);
      addTearDown(c.dispose);
      expect(c.workspaceMode, WorkspaceManagementMode.interleaved);

      await c.setWorkspaceMode(WorkspaceManagementMode.grouped);
      expect(c.workspaceMode, WorkspaceManagementMode.grouped);

      await c.setWorkspaceMode(WorkspaceManagementMode.off);
      expect(c.workspaceMode, WorkspaceManagementMode.off);
      expect(c.config.writeOptions.injectSwayWorkspaceExec, isFalse);
    });
  });

  group('a config written by the broken version', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('kanshi_mig_'));
    tearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    String onDisk() => File('${tmp.path}/config').readAsStringSync();

    /// Writes the exact shape the reporter had: an observed map that replaced
    /// the rule, so only the workspaces that happened to be open got a home.
    Future<ConfigService> broken({List<MonitorTileData>? monitors}) async {
      final writer = ConfigService(
        configPath: '${tmp.path}/config',
        backupPrefix: '${tmp.path}/backups/config.bak',
        writeOptions: KanshiWriteOptions.swayDefaults
            .copyWith(followProfileWorkspaceMap: true),
      );
      await writer.saveProfiles([
        Profile(
          name: 'Office',
          monitors: monitors ?? desk(),
          workspaceMap: {1: 'DP-4', 2: 'DP-5', 3: 'eDP-1', 8: 'eDP-1'},
        ),
      ]);
      return ConfigService(
        configPath: '${tmp.path}/config',
        backupPrefix: '${tmp.path}/backups/config.bak',
        writeOptions: KanshiWriteOptions.swayDefaults,
      );
    }

    Future<KanshiController> launch(ConfigService config,
        {List<MonitorTileData>? outputs}) async {
      final c = KanshiController(
        monitors: FakeMonitorService(
            outputs: outputs ?? desk(),
            writeOptions: KanshiWriteOptions.swayDefaults),
        config: config,
        mirrorRunner: FakeMirrorRunner(),
        workspaceDistribution: WorkspaceDistribution.interleaved,
      );
      await c.init();
      return c;
    }

    test('is repaired on the next launch, not on the next edit', () async {
      // Without this the file keeps its truncated chain until the user
      // happens to move a screen — and the file is all there is once the
      // window is closed, because kanshi replays it on every dock.
      final config = await broken();
      final c = await launch(config);
      addTearDown(c.dispose);

      for (var ws = 1; ws <= 9; ws++) {
        expect(onDisk(), contains('workspace $ws output '),
            reason: 'workspace $ws still has no home in the file');
      }
      expect(onDisk(), contains("workspace 8 output 'DP-5'"),
          reason: 'the stray observation must give way to the rule');
      expect(onDisk(), isNot(contains('kanshi_gui:ws')));
    });

    test('is left alone while the user asked to be followed', () async {
      final config = ConfigService(
        configPath: '${tmp.path}/config',
        backupPrefix: '${tmp.path}/backups/config.bak',
        writeOptions: KanshiWriteOptions.swayDefaults
            .copyWith(followProfileWorkspaceMap: true),
      );
      await broken();
      final c = KanshiController(
        monitors: FakeMonitorService(
            outputs: desk(), writeOptions: KanshiWriteOptions.swayDefaults),
        config: config,
        mirrorRunner: FakeMirrorRunner(),
        workspaceDistribution: WorkspaceDistribution.interleaved,
        followProfileWorkspaceMap: true,
        learnWorkspaceMapFromLive: true,
      );
      addTearDown(c.dispose);
      await c.init();
      expect(c.profiles.first.workspaceMap, isNotNull,
          reason: 'their preference is not the app\'s to throw away');
    });

    test('does not drag a setup the user never made into the file', () async {
      // The repair writes the whole profile list, and opening the app against
      // screens no setup matches ADDS a scratch capture to that list in
      // memory. init() is explicit that a launch must not persist it.
      final config = await broken();
      final c = await launch(config, outputs: [_mon('HDMI-A-1', 0)]);
      addTearDown(c.dispose);

      expect(onDisk(), isNot(contains('Setup 1')),
          reason: 'a launch must not invent a setup in the user\'s config');
      expect(onDisk(), contains("profile 'Office'"));
    });

    test('a chain that never mentioned workspace 1 is still replaced', () async {
      // The app recognised its own exec line by the literal `workspace number
      // 1`, which a chain built from an observation without workspace 1 does
      // not contain — so it kept the old line and wrote a second one, and sway
      // got two contradictory sets of homes.
      // Written by hand: the current writer can no longer produce this shape,
      // which is the point — but a config on someone's disk still can.
      File('${tmp.path}/config').writeAsStringSync('''
profile 'Office' {
    output "DP-4" enable scale 1.00 mode 2560x1440@60Hz transform normal position 8072,0
    output "DP-5" enable scale 1.00 mode 2560x1440@60Hz transform normal position 10632,0
    output "eDP-1" enable scale 1.00 mode 2560x1440@60Hz transform normal position 13192,0
    # kanshi_gui:ws '4'='DP-4'
    # kanshi_gui:ws '5'='DP-5'
    exec swaymsg "workspace 4 output 'DP-4'; workspace 5 output 'DP-5'; workspace number 4; move workspace to output 'DP-4'; workspace number 5; move workspace to output 'DP-5'; workspace number 4"
}
''');
      expect(onDisk(), isNot(contains('workspace number 1')),
          reason: 'the fixture has to reproduce the shape that broke');

      final c = await launch(ConfigService(
        configPath: '${tmp.path}/config',
        backupPrefix: '${tmp.path}/backups/config.bak',
        writeOptions: KanshiWriteOptions.swayDefaults,
      ));
      addTearDown(c.dispose);

      final chains = RegExp('exec swaymsg "workspace')
          .allMatches(onDisk())
          .length;
      expect(chains, 1, reason: 'two chains means sway is told two things');
    });
  });

  group('entering "keep them where I put them"', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('kanshi_enter_'));
    tearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    test('records where they are before it moves anything', () async {
      // The mode promises not to touch them. Applying first and observing
      // afterwards would scatter them onto the rule and then record the
      // scattering as the user's preference.
      final config = ConfigService(
        configPath: '${tmp.path}/config',
        backupPrefix: '${tmp.path}/backups/config.bak',
        writeOptions: KanshiWriteOptions.swayDefaults,
      );
      await config.saveProfiles([Profile(name: 'Office', monitors: desk())]);
      // Deliberately NOT the interleaved rule: 2 belongs to DP-5 under it.
      final live = {1: 'DP-4', 2: 'eDP-1', 3: 'DP-5'};
      final fake = FakeMonitorService(
          outputs: desk(), writeOptions: KanshiWriteOptions.swayDefaults)
        ..workspaceOutputs = live;
      final c = KanshiController(
        monitors: fake,
        config: config,
        mirrorRunner: FakeMirrorRunner(),
        workspaceDistribution: WorkspaceDistribution.interleaved,
      );
      addTearDown(c.dispose);
      await c.init();

      await c.setWorkspaceMode(WorkspaceManagementMode.learned);
      expect(c.activeProfile?.workspaceMap, live,
          reason: 'the arrangement it found is the one it must keep');
      expect(fake.workspaceChainCalls.last, contains("workspace 2 output 'eDP-1'"),
          reason: 'the chain it then applies must honour what it recorded');
    });
  });

  group('the settings file', () {
    test('every mode survives a round-trip', () {
      for (final mode in WorkspaceManagementMode.values) {
        expect(WorkspaceManagementMode.fromJson(mode.jsonValue), mode);
      }
    });

    test('a mode written by a newer version reads as off, not as a rule', () {
      expect(WorkspaceManagementMode.fromJson('spiral'),
          WorkspaceManagementMode.off);
    });

    test('the following mode still needs a rule to fill its gaps', () {
      expect(WorkspaceManagementMode.learned.distribution,
          WorkspaceDistribution.interleaved);
      expect(WorkspaceManagementMode.learned.learns, isTrue);
      expect(WorkspaceManagementMode.interleaved.learns, isFalse);
      expect(WorkspaceManagementMode.off.distribution, isNull);
    });
  });
}
