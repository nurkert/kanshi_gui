import 'package:flutter_test/flutter_test.dart';
import 'package:kanshi_gui/domain/workspace_layout.dart';
import 'package:kanshi_gui/models/monitor_tile_data.dart';
import 'package:kanshi_gui/state/workspace_placement.dart';

import 'fakes/fake_monitor_service.dart';

MonitorTileData _mon({
  required String id,
  double x = 0,
  String descriptor = '',
  bool enabled = true,
  String? mirrorOf,
}) =>
    MonitorTileData(
      id: id,
      manufacturer: id,
      edidDescriptor: descriptor,
      x: x,
      y: 0,
      width: 1920,
      height: 1080,
      rotation: 0,
      refresh: 60,
      resolution: '1920x1080',
      orientation: 'landscape',
      enabled: enabled,
      mirrorOf: mirrorOf,
    );

void main() {
  group('needsRepair', () {
    final want = {1: 'eDP-1', 2: 'DP-1', 3: 'HDMI-A-2'};

    test('an absent workspace is not a mismatch', () {
      // sway does not pre-create empty workspaces. The chain's
      // `workspace number N output X` already declared the home, and it is
      // honoured on first focus — re-running for that would be churn.
      expect(WorkspacePlacement.needsRepair(want, {1: 'eDP-1'}), isFalse);
    });

    test('a workspace living on the wrong output is', () {
      expect(
        WorkspacePlacement.needsRepair(want, {1: 'eDP-1', 2: 'HDMI-A-2'}),
        isTrue,
      );
    });

    test('a stuck out-of-range workspace is', () {
      // Typically a workspace 10 left over from an earlier session.
      expect(
        WorkspacePlacement.needsRepair(want, {1: 'eDP-1', 10: 'DP-1'}),
        isTrue,
      );
    });
  });

  group('expectedMapping', () {
    test('interleaved walks the number keys left to right', () {
      final ranked = [
        const WorkspaceRankEntry('L', 0, false),
        const WorkspaceRankEntry('R', 1, false),
      ];
      final m = WorkspacePlacement.expectedMapping(
          ranked, WorkspaceDistribution.interleaved);
      expect([m[1], m[2], m[3], m[4]], ['L', 'R', 'L', 'R']);
    });

    test('grouped carves contiguous bands', () {
      final ranked = [
        const WorkspaceRankEntry('L', 0, false),
        const WorkspaceRankEntry('R', 1, false),
      ];
      final m = WorkspacePlacement.expectedMapping(
          ranked, WorkspaceDistribution.grouped);
      expect(m[1], 'L');
      expect(m[9], 'R');
    });
  });

  group('verifyAndFix', () {
    Future<FakeMonitorService> run({
      required bool enabled,
      Map<int, String> live = const {},
      bool force = false,
      List<MonitorTileData>? profile,
    }) async {
      final fake = FakeMonitorService(
        outputs: [_mon(id: 'eDP-1'), _mon(id: 'DP-1', x: 1920)],
      );
      fake.workspaceOutputs = live;
      await WorkspacePlacement(fake).verifyAndFix(
        enabled: enabled,
        profileMonitors:
            profile ?? [_mon(id: 'eDP-1'), _mon(id: 'DP-1', x: 1920)],
        liveOutputs: [_mon(id: 'eDP-1'), _mon(id: 'DP-1', x: 1920)],
        distribution: WorkspaceDistribution.interleaved,
        resolveConnector: (id) => id,
        force: force,
      );
      return fake;
    }

    test('does nothing at all when workspace management is off', () async {
      // The user's opt-in. With it off we must not touch the live layout,
      // not even to read it.
      final fake = await run(enabled: false, live: {1: 'DP-1'});
      expect(fake.calls, isEmpty);
    });

    test('leaves a correct mapping alone', () async {
      final fake = await run(enabled: true, live: {1: 'eDP-1', 2: 'DP-1'});
      expect(fake.calls.where((c) => c.startsWith('workspaceChain')), isEmpty);
    });

    test('repairs a wrong mapping', () async {
      final fake = await run(enabled: true, live: {1: 'DP-1', 2: 'eDP-1'});
      expect(
          fake.calls.where((c) => c.startsWith('workspaceChain')), isNotEmpty);
    });

    test('force re-runs even when the live mapping already agrees', () async {
      // `kanshictl reload` does not re-fire the exec line for a profile that
      // is already active, so a caller that just mutated it has to insist.
      final fake = await run(
          enabled: true, live: {1: 'eDP-1', 2: 'DP-1'}, force: true);
      expect(
          fake.calls.where((c) => c.startsWith('workspaceChain')), isNotEmpty);
    });

    test('mirror destinations are excluded, matching the writer', () async {
      final fake = await run(
        enabled: true,
        force: true,
        profile: [
          _mon(id: 'eDP-1'),
          _mon(id: 'DP-1', x: 1920, mirrorOf: 'eDP-1'),
        ],
      );
      final chain = fake.calls.firstWhere((c) => c.startsWith('workspaceChain'));
      expect(chain, contains("'eDP-1'"));
      // Quoted, because the substring 'DP-1' also occurs inside 'eDP-1'.
      expect(chain, isNot(contains("'DP-1'")),
          reason: 'a mirror destination shows the source, so it owns no '
              'workspaces of its own');
    });

    test('the repair chain uses the same stable identity as the config',
        () async {
      // The old in-controller version built the chain without criteria, so
      // the repair addressed outputs by connector while the config addressed
      // them by EDID description — the two could disagree about which screen
      // a workspace belongs on.
      final fake = await run(
        enabled: true,
        force: true,
        profile: [
          _mon(id: 'eDP-1', descriptor: 'Acme Panel SN1'),
          _mon(id: 'DP-1', x: 1920, descriptor: 'Acme Wide SN2'),
        ],
      );
      final chain = fake.calls.firstWhere((c) => c.startsWith('workspaceChain'));
      expect(chain, contains("'Acme Panel SN1'"));
      expect(chain, contains("'Acme Wide SN2'"));
    });
  });
}
