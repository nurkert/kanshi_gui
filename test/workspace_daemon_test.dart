import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kanshi_gui/domain/workspace_layout.dart';
import 'package:kanshi_gui/domain/workspace_plan.dart';
import 'package:kanshi_gui/models/monitor_tile_data.dart';
import 'package:kanshi_gui/models/profiles.dart';
import 'package:kanshi_gui/services/workspace_daemon.dart';

import 'fakes/fake_process_runner.dart';

/// The helper that keeps the workspaces right with the app closed.
///
/// Two things it must never do, both of which are worse than doing nothing:
/// act on a desk it does not recognise (which pins workspaces to a monitor
/// that is not there), and disagree with the app about where a workspace
/// belongs. The second is why it is compiled from the same domain code rather
/// than reimplemented in shell.
MonitorTileData _mon(
  String id, {
  double x = 0,
  String? descriptor,
  bool enabled = true,
  String? mirrorOf,
}) =>
    MonitorTileData(
      id: id,
      manufacturer: 'Panel $id',
      edidDescriptor: descriptor ?? 'Make $id Serial$id',
      x: x,
      y: 0,
      width: 2560,
      height: 1440,
      scale: 1.0,
      rotation: 0,
      refresh: 60,
      resolution: '2560x1440',
      orientation: 'landscape',
      enabled: enabled,
      mirrorOf: mirrorOf,
    );

List<MonitorTileData> desk() =>
    [_mon('DP-4'), _mon('DP-5', x: 2560), _mon('eDP-1', x: 5120)];

void main() {
  group('recognising the desk', () {
    test('the setup whose screens are exactly these', () {
      final plan = planWorkspaces(
        profiles: [
          Profile(name: 'Laptop', monitors: [_mon('eDP-1')]),
          Profile(name: 'Office', monitors: desk()),
        ],
        live: desk(),
        distribution: WorkspaceDistribution.interleaved,
      );
      expect(plan?.profile.name, 'Office');
      expect(plan?.map, {
        1: 'DP-4',
        2: 'DP-5',
        3: 'eDP-1',
        4: 'DP-4',
        5: 'DP-5',
        6: 'eDP-1',
        7: 'DP-4',
        8: 'DP-5',
        9: 'eDP-1',
      });
    });

    test('a setup that names only some of these screens is not this desk', () {
      // Half a plan applied to a desk the helper does not recognise is how a
      // workspace ends up pinned to a monitor that is not plugged in.
      final plan = planWorkspaces(
        profiles: [
          Profile(name: 'Two of three', monitors: [_mon('DP-4'), _mon('DP-5')]),
        ],
        live: desk(),
        distribution: WorkspaceDistribution.interleaved,
      );
      expect(plan, isNull);
    });

    test('nothing matching means nothing at all', () {
      expect(
        planWorkspaces(
          profiles: [Profile(name: 'Elsewhere', monitors: [_mon('HDMI-A-1')])],
          live: desk(),
          distribution: WorkspaceDistribution.interleaved,
        ),
        isNull,
      );
    });

    test('placement switched off produces no plan', () {
      expect(
        planWorkspaces(
          profiles: [Profile(name: 'Office', monitors: desk())],
          live: desk(),
          distribution: null,
        ),
        isNull,
      );
    });

    test("kanshi's marker breaks a tie between two setups for one desk", () {
      // Two remembered arrangements of the same three screens: the hardware
      // cannot tell them apart, and kanshi has already decided which one it
      // activated.
      final a = Profile(name: 'Desk, wide left', monitors: desk());
      final b = Profile(name: 'Desk, wide right', monitors: desk());
      expect(
        planWorkspaces(
          profiles: [a, b],
          live: desk(),
          distribution: WorkspaceDistribution.interleaved,
          preferProfileName: 'Desk, wide right',
        )?.profile.name,
        'Desk, wide right',
      );
    });

    test('a marker naming a setup that is not plugged in is ignored', () {
      // The file survives reboots and describes yesterday's desk until kanshi
      // gets round to rewriting it. Trusting it would apply the office layout
      // to a laptop on a train.
      expect(
        planWorkspaces(
          profiles: [Profile(name: 'Office', monitors: desk())],
          live: desk(),
          distribution: WorkspaceDistribution.interleaved,
          preferProfileName: 'Cafe',
        )?.profile.name,
        'Office',
      );
    });
  });

  group('the plan', () {
    test('a mirror destination gets no workspaces of its own', () {
      final mons = [
        _mon('DP-4'),
        _mon('DP-5', x: 2560, mirrorOf: 'DP-4'),
      ];
      final plan = planWorkspaces(
        profiles: [Profile(name: 'Mirrored', monitors: mons)],
        live: mons,
        distribution: WorkspaceDistribution.interleaved,
      );
      expect(plan!.map.values.toSet(), {'DP-4'});
    });

    test('a screen the setup disables gets none either', () {
      final mons = [_mon('DP-4'), _mon('DP-5', x: 2560, enabled: false)];
      final plan = planWorkspaces(
        profiles: [Profile(name: 'One on', monitors: mons)],
        live: mons,
        distribution: WorkspaceDistribution.interleaved,
      );
      expect(plan!.map.values.toSet(), {'DP-4'});
    });

    test('a setup addressed by EDID is restated in live connectors', () {
      // The config remembers a screen by its description; the port it is on
      // this boot is whatever the kernel handed out.
      final profile = Profile(name: 'Office', monitors: [
        _mon('Make DP-4 SerialDP-4', descriptor: 'Make DP-4 SerialDP-4'),
      ]);
      final plan = planWorkspaces(
        profiles: [profile],
        live: [_mon('DP-9', descriptor: 'Make DP-4 SerialDP-4')],
        distribution: WorkspaceDistribution.interleaved,
      );
      expect(plan?.map[1], 'DP-9');
    });

    test('two panels of the same model are told apart by port', () {
      // kanshi cannot resolve a description two screens share, and sway
      // silently drops the target it cannot resolve — which would land both
      // screens' workspaces on whichever one it found first.
      final mons = [
        _mon('DP-4', descriptor: 'Samsung LF27T850 Unknown'),
        _mon('DP-5', x: 2560, descriptor: 'Samsung LF27T850 Unknown'),
      ];
      final plan = planWorkspaces(
        profiles: [Profile(name: 'Twins', monitors: mons)],
        live: mons,
        distribution: WorkspaceDistribution.interleaved,
      );
      expect(plan!.chain, contains("workspace 1 output 'DP-4'"));
      expect(plan.chain, contains("workspace 2 output 'DP-5'"));
    });

    test('a hand-made map is followed only when asked for', () {
      final profile = Profile(name: 'Office', monitors: desk())
        ..workspaceMap = {9: 'DP-4'};
      Map<int, String>? mapWith({required bool follow}) => planWorkspaces(
            profiles: [profile],
            live: desk(),
            distribution: WorkspaceDistribution.interleaved,
            followProfileMap: follow,
          )?.map;

      expect(mapWith(follow: true)![9], 'DP-4');
      expect(mapWith(follow: false)![9], 'eDP-1',
          reason: 'a rule mode must not be outvoted by a leftover map');
    });

    test('declarations alone touch nothing that exists', () {
      final plan = planWorkspaces(
        profiles: [Profile(name: 'Office', monitors: desk())],
        live: desk(),
        distribution: WorkspaceDistribution.interleaved,
      )!;
      expect(plan.declarations, isNot(contains('move workspace')));
      expect(plan.declarations, isNot(contains('workspace number')));
      expect(plan.chain, contains('move workspace to output'));
    });

    test('a block per screen is the other pattern', () {
      final plan = planWorkspaces(
        profiles: [Profile(name: 'Office', monitors: desk())],
        live: desk(),
        distribution: WorkspaceDistribution.grouped,
      )!;
      expect(plan.map[1], 'DP-4');
      expect(plan.map[3], 'DP-4');
      expect(plan.map[4], 'DP-5');
      expect(plan.map[9], 'eDP-1');
    });
  });

  group('the chain hands focus back', () {
    test('it ends where the user was, not on workspace 1', () {
      // Run from a background service while someone is working on workspace
      // 6, ending on 1 takes their screen away for no reason they can see.
      final map = {1: 'DP-4', 2: 'DP-5', 3: 'eDP-1'};
      expect(buildWorkspaceChain(map, returnFocusTo: 6),
          endsWith('workspace number 6'));
      expect(buildWorkspaceChain(map), endsWith('workspace number 1'),
          reason: 'with nobody to hand back to, the old landing stands');
      expect(buildWorkspaceChain(map, returnFocusTo: null),
          endsWith('workspace number 1'));
    });
  });

  group('reading sway events', () {
    test('an output event means work it out again', () {
      // The exact payload a live sway sends. It carries NOTHING else — no
      // output name, no rect. This code looked for an `output` key, which
      // does not exist, so docking replanned nothing for a whole release.
      expect(classifySwayEvent({'change': 'unspecified'}).action,
          SwayEventAction.replan);
    });

    test('a malformed event with no change at all still replans', () {
      // Failing towards "look again" is right here: the cost is one cheap
      // recomputation, and the alternative is the daemon going deaf.
      expect(classifySwayEvent(const {}).action, SwayEventAction.replan);
    });

    test('a reload means work it out again', () {
      // `swaymsg reload` discards every workspace config sway holds — ours
      // included. It is also the documented way out of a workspace stuck on
      // the wrong screen, so it is precisely when to re-declare.
      expect(classifySwayEvent({'change': 'reload'}).action,
          SwayEventAction.replan);
    });

    test('a workspace being born is NOT acted on', () {
      // This used to move it, and moving a workspace means focusing it —
      // which leaves the previous one empty, which sway garbage-collects,
      // which the next command recreates. 975 workspace events in three
      // seconds on a real desk: a third of a core, focus yanked between
      // screens faster than a cursor could be moved, windows appearing to
      // vanish as their workspace was destroyed and remade under them.
      //
      // A helper must not answer events its own commands produce. sway places
      // a new workspace correctly by itself now that the `workspace N output
      // X` bindings actually reach it.
      expect(
        classifySwayEvent({
          'change': 'init',
          'current': {'num': 8, 'name': '8', 'output': 'eDP-1'},
        }).action,
        SwayEventAction.none,
      );
    });

    test('nor is any other workspace event', () {
      for (final change in ['init', 'focus', 'empty', 'move', 'rename',
        'urgent']) {
        expect(
          classifySwayEvent({
            'change': change,
            'current': {'num': 3, 'output': 'DP-4'},
          }).action,
          SwayEventAction.none,
          reason: '$change must not make the helper issue a command',
        );
      }
    });

    test('a workspace event that says nothing usable moves nothing', () {
      expect(
        classifySwayEvent({'change': 'init', 'current': 'nonsense'}).action,
        SwayEventAction.none,
      );
      expect(
        classifySwayEvent({
          'change': 'init',
          'current': {'name': 'scratch'},
        }).action,
        SwayEventAction.none,
      );
    });
  });

  group('the switch', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('kanshi_daemon_'));
    tearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    String unitFile() {
      final f = File('${tmp.path}/kanshi-gui-workspaces.service')
        ..writeAsStringSync('[Unit]\n');
      return f.path;
    }

    test('no unit on the machine means the switch is not offered', () async {
      final d = WorkspaceDaemon(
        runner: FakeProcessRunner(installed: {'systemctl'}),
        searchPaths: ['${tmp.path}/absent.service'],
      );
      expect(await d.state(), WorkspaceDaemonState.unavailable);
    });

    test('no systemctl means the same', () async {
      final d = WorkspaceDaemon(
        runner: FakeProcessRunner(),
        searchPaths: [unitFile()],
      );
      expect(await d.state(), WorkspaceDaemonState.unavailable);
    });

    test('the word on stdout decides, not the exit code', () async {
      // `systemctl is-enabled` exits non-zero for disabled, static and masked
      // alike. Reading the exit code would report every switched-off service
      // as broken.
      final d = WorkspaceDaemon(
        runner: FakeProcessRunner(
          installed: {'systemctl'},
          responses: {
            'systemctl --user is-enabled kanshi-gui-workspaces.service':
                ProcessResult(0, 1, 'disabled\n', ''),
          },
        ),
        searchPaths: [unitFile()],
      );
      expect(await d.state(), WorkspaceDaemonState.disabled);
    });

    test('enabled is enabled', () async {
      final d = WorkspaceDaemon(
        runner: FakeProcessRunner(
          installed: {'systemctl'},
          responses: {
            'systemctl --user is-enabled kanshi-gui-workspaces.service':
                ProcessResult(0, 0, 'enabled\n', ''),
          },
        ),
        searchPaths: [unitFile()],
      );
      expect(await d.state(), WorkspaceDaemonState.enabled);
    });

    test('turning it on reloads first, then enables for this user only',
        () async {
      final runner = FakeProcessRunner(
        installed: {'systemctl'},
        fallback: ProcessResult(0, 0, '', ''),
      );
      await WorkspaceDaemon(runner: runner, searchPaths: [unitFile()])
          .setEnabled(true);
      expect(runner.calls, [
        ['systemctl', '--user', 'daemon-reload'],
        [
          'systemctl',
          '--user',
          'enable',
          '--now',
          'kanshi-gui-workspaces.service'
        ],
      ]);
    });

    test('turning it off stops it too', () async {
      final runner = FakeProcessRunner(
        installed: {'systemctl'},
        fallback: ProcessResult(0, 0, '', ''),
      );
      await WorkspaceDaemon(runner: runner, searchPaths: [unitFile()])
          .setEnabled(false);
      expect(runner.calls.last, [
        'systemctl',
        '--user',
        'disable',
        '--now',
        'kanshi-gui-workspaces.service'
      ]);
    });

    test('systemd refusing is raised, not swallowed', () async {
      final d = WorkspaceDaemon(
        runner: FakeProcessRunner(
          installed: {'systemctl'},
          responses: {
            'systemctl --user enable --now kanshi-gui-workspaces.service':
                ProcessResult(0, 1, '', 'Failed to connect to bus.'),
          },
          fallback: ProcessResult(0, 0, '', ''),
        ),
        searchPaths: [unitFile()],
      );
      expect(
        () => d.setEnabled(true),
        throwsA(isA<WorkspaceDaemonException>().having(
            (e) => e.message, 'message', contains('Failed to connect'))),
      );
    });
  });
}
