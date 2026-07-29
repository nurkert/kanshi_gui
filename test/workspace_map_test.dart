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

MonitorTileData _mon({required String id, double x = 0}) => MonitorTileData(
      id: id,
      manufacturer: id,
      x: x,
      y: 0,
      width: 1920,
      height: 1080,
      rotation: 0,
      refresh: 60,
      resolution: '1920x1080',
      orientation: 'landscape',
    );

/// Where the workspaces go is learned, not configured. "Interleaved or
/// grouped?" is a question nobody can answer without trying both; people know
/// where they want their workspaces and express it by putting them there.
void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('kanshi_ws_'));
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  ConfigService cfg() => ConfigService(
        configPath: '${tmp.path}/config',
        backupPrefix: '${tmp.path}/backups/config.bak',
        writeOptions: KanshiWriteOptions.swayDefaults,
      );

  group('persistence', () {
    test('an observed map round-trips through the config', () async {
      final c = cfg();
      await c.saveProfiles([
        Profile(
          name: 'Desk',
          monitors: [_mon(id: 'A'), _mon(id: 'B', x: 1920)],
          workspaceMap: {1: 'A', 2: 'B', 3: 'A'},
        ),
      ]);
      final back = KanshiConfigParser.parse(
          File('${tmp.path}/config').readAsStringSync());
      expect(back.single.workspaceMap, {1: 'A', 2: 'B', 3: 'A'});
    });

    test('a setup that has never been observed carries no map', () async {
      final c = cfg();
      await c.saveProfiles([
        Profile(name: 'Desk', monitors: [_mon(id: 'A')]),
      ]);
      final back = KanshiConfigParser.parse(
          File('${tmp.path}/config').readAsStringSync());
      expect(back.single.workspaceMap, isNull);
    });

    test('the chain follows the observed map, not the distribution rule',
        () async {
      final c = cfg();
      await c.saveProfiles([
        Profile(
          name: 'Desk',
          monitors: [_mon(id: 'A'), _mon(id: 'B', x: 1920)],
          // Deliberately NOT what interleaving would produce.
          workspaceMap: {1: 'B', 2: 'B', 3: 'A'},
        ),
      ]);
      final text = File('${tmp.path}/config').readAsStringSync();
      expect(text, contains("workspace 1 output 'B'"));
      expect(text, contains("workspace 2 output 'B'"));
      expect(text, contains("workspace 3 output 'A'"));
    });
  });

  group('buildLearnedWorkspaceChain', () {
    test('declares homes first, then force-moves', () {
      final chain = buildLearnedWorkspaceChain({1: 'A', 2: 'B'})!;
      final declare = chain.indexOf("workspace 1 output 'A'");
      final move = chain.indexOf("move workspace to output 'A'");
      expect(declare, lessThan(move),
          reason: 'a workspace must have a home before it is sent there');
      expect(chain, endsWith('workspace number 1'));
    });

    test('an empty map produces nothing', () {
      expect(buildLearnedWorkspaceChain(const {}), isNull);
    });
  });

  group('learning is cautious about the moment', () {
    Future<KanshiController> build(FakeMonitorService fake,
        {required Map<int, String> live}) async {
      final c = cfg();
      await c.saveProfiles([
        Profile(name: 'Desk', monitors: [_mon(id: 'A'), _mon(id: 'B', x: 1920)]),
      ]);
      fake.workspaceOutputs = live;
      final ctl = KanshiController(
        monitors: fake,
        config: c,
        mirrorRunner: FakeMirrorRunner(),
        // Workspace management on: without it the app must not touch the
        // live workspace layout at all, so there is nothing to learn.
        workspaceDistribution: WorkspaceDistribution.interleaved,
      );
      await ctl.init();
      return ctl;
    }

    test('records a mapping it can attribute to this setup', () async {
      final fake = FakeMonitorService(
          outputs: [_mon(id: 'A'), _mon(id: 'B', x: 1920)],
          writeOptions: KanshiWriteOptions.swayDefaults);
      final c = await build(fake, live: {1: 'A', 2: 'B'});
      expect(c.activeProfile?.workspaceMap, {1: 'A', 2: 'B'});
      c.dispose();
    });

    test('refuses when a workspace sits on a screen this setup does not have',
        () async {
      // A transient state — a screen mid-unplug, or another setup's leftovers.
      // Recording it would cement an arrangement the user never chose.
      final fake = FakeMonitorService(
          outputs: [_mon(id: 'A'), _mon(id: 'B', x: 1920)],
          writeOptions: KanshiWriteOptions.swayDefaults);
      final c = await build(fake, live: {1: 'A', 2: 'STRANGER'});
      expect(c.activeProfile?.workspaceMap, isNull);
      c.dispose();
    });

    test('refuses while the layout has drifted', () async {
      // The screens are not where the setup says, so neither are the
      // workspaces — and this is the very failure the feature exists to fix.
      final fake = FakeMonitorService(
          outputs: [_mon(id: 'A'), _mon(id: 'B', x: 9000)],
          writeOptions: KanshiWriteOptions.swayDefaults);
      final c = await build(fake, live: {1: 'A', 2: 'B'});
      expect(c.hasLayoutDrift, isTrue);
      expect(await c.learnWorkspaceMap(), isFalse);
      c.dispose();
    });

    test('refuses when the compositor reports nothing', () async {
      final fake = FakeMonitorService(
          outputs: [_mon(id: 'A'), _mon(id: 'B', x: 1920)],
          writeOptions: KanshiWriteOptions.swayDefaults);
      final c = await build(fake, live: const {});
      expect(c.activeProfile?.workspaceMap, isNull);
      c.dispose();
    });

    test('does not rewrite the config when nothing changed', () async {
      final fake = FakeMonitorService(
          outputs: [_mon(id: 'A'), _mon(id: 'B', x: 1920)],
          writeOptions: KanshiWriteOptions.swayDefaults);
      final c = await build(fake, live: {1: 'A', 2: 'B'});
      expect(await c.learnWorkspaceMap(), isFalse,
          reason: 'the same observation twice is not a change');
      c.dispose();
    });
  });
}
