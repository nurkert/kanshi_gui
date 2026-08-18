import 'package:flutter_test/flutter_test.dart';
import 'package:kanshi_gui/models/monitor_tile_data.dart';
import 'package:kanshi_gui/models/profiles.dart';
import 'package:kanshi_gui/domain/workspace_plan.dart';
import 'package:kanshi_gui/services/app_settings.dart';
import 'package:kanshi_gui/services/workspace_daemon_core.dart';

import 'fakes/fake_sway.dart';

/// The test that was missing.
///
/// Seven hundred tests did not catch the helper feeding itself, and none of
/// them could have: every one asserted on the strings the code produced, and
/// the bug lived in what the compositor did with them afterwards. It cost a
/// user their morning — 975 workspace events in three seconds, a third of a
/// core held, focus yanked between screens faster than a cursor could be
/// moved, windows appearing to vanish.
///
/// So this file drives the deciding half with a sway that answers commands
/// the way the real one does, and asserts on the only thing that matters for
/// this class of bug: **how many commands come back out**.
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
  late FakeSway sway;
  late FakeEnvironment env;
  late WorkspaceDaemonCore core;

  /// Wires the core to the fake exactly the way the binary wires it to the
  /// real thing: every event goes through [WorkspaceDaemonCore.reasonFor] and,
  /// if it means anything, through the same serialising queue.
  void wire() {
    sway.events().listen((e) {
      final verdict = classifySwayEvent(e);
      switch (verdict.action) {
        case SwayEventAction.none:
          return;
        case SwayEventAction.correct:
        core.noteFocus(verdict.workspace!);
          core.serialised(
              () => core.correct(verdict.workspace!, verdict.output!));
        case SwayEventAction.userMoved:
        // sway emits `move` for our own corrections too; the core tells the
        // two apart because it knows what it just sent.
        core.noteMove(verdict.workspace!, verdict.output!);
        return;
      case SwayEventAction.replan:
          core.serialised(() => core.apply(ApplyReason.outputsChanged));
      }
    });
  }

  /// Lets every queued microtask and event settle.
  Future<void> settle([int rounds = 40]) async {
    for (var i = 0; i < rounds; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  setUp(() {
    sway = FakeSway(
      live: desk(),
      // A desk mid-dock: everything still on the laptop, which is what makes
      // the plan disagree and the visible repair run.
      workspaces: {1: 'eDP-1', 2: 'eDP-1', 6: 'eDP-1'},
      focused: 6,
    );
    env = FakeEnvironment(
      mode: WorkspaceManagementMode.interleaved,
      knownProfiles: [Profile(name: 'Office', monitors: desk())],
    );
    core = WorkspaceDaemonCore(sway: sway, env: env);
    wire();
  });

  tearDown(() => sway.dispose());

  group('the helper does not answer its own commands', () {
    test('one hotplug produces one command, not a storm', () async {
      sway.hotplug();
      await settle();

      expect(sway.commands, hasLength(1),
          reason: 'the incident was 65 of these in three seconds');
      // And it was the repair, because the desk genuinely disagreed.
      expect(sway.commands.single, contains('move workspace to output'));
    });

    test('the churn its own repair causes is ignored', () async {
      // The fake answers a focus-and-move chain with focus/move/empty/init
      // for every workspace — the exact shape captured from the live
      // incident. None of it may come back as another command.
      sway.hotplug();
      await settle();
      final afterFirst = sway.commands.length;

      await settle(200);

      expect(sway.commands.length, afterFirst,
          reason: 'every command it sent was answered by events it must not '
              'act on');
    });

    test('a user switching workspaces all day produces nothing', () async {
      for (var i = 0; i < 50; i++) {
        sway.userSwitchedTo(i % 9 + 1, 'DP-4');
      }
      await settle();

      expect(sway.commands, isEmpty,
          reason: 'moving between workspaces is the user talking, not a '
              'reason to rearrange their desk');
    });

    test('a storm of hotplugs is bounded by the standing-down guard',
        () async {
      // If some future wiring mistake does reintroduce a loop, the guard is
      // the thing that stops it being a desktop nobody can use.
      for (var i = 0; i < 200; i++) {
        await core.apply(ApplyReason.outputsChanged);
      }
      expect(sway.commands.length,
          lessThanOrEqualTo(WorkspaceDaemonCore.applyCeiling));
    });
  });

  group('what it does when it does act', () {
    test('it hands focus back to where the user was', () async {
      sway.focused = 6;
      sway.hotplug();
      await settle();

      expect(sway.commands.single, endsWith('workspace number 6'),
          reason: 'ending on workspace 1 takes their screen away');
    });

    test('a config change never moves what is already open', () async {
      // Same disagreeing desk; only the reason differs.
      await core.apply(ApplyReason.configChanged);

      expect(sway.commands.single, isNot(contains('move workspace to output')),
          reason: 'a settings change is not a reason to rearrange a desk');
      expect(sway.commands.single, contains('workspace 1 output'));
    });

    test('starting up never moves what is already open either', () async {
      await core.apply(ApplyReason.startup);
      expect(sway.commands.single, isNot(contains('move workspace to output')));
    });

    test('a desk that already agrees is only ever declared to', () async {
      sway = FakeSway(
        live: desk(),
        workspaces: {1: 'DP-4', 2: 'DP-5', 6: 'eDP-1'},
        focused: 1,
      );
      core = WorkspaceDaemonCore(sway: sway, env: env);
      wire();

      sway.hotplug();
      await settle();

      expect(sway.commands.single, isNot(contains('move workspace to output')));
    });

    test('placement switched off means silence', () async {
      env.mode = WorkspaceManagementMode.off;
      sway.hotplug();
      await settle();
      expect(sway.commands, isEmpty);
    });

    test('a desk it does not recognise means silence', () async {
      env.knownProfiles = [
        Profile(name: 'Elsewhere', monitors: [_mon('HDMI-A-1', 0)]),
      ];
      sway.hotplug();
      await settle();
      expect(sway.commands, isEmpty,
          reason: 'half a plan on an unrecognised desk pins workspaces to a '
              'monitor that is not there');
    });

    test('the by-hand list survives a re-apply of the same placement',
        () async {
      // Keyed on the placement rather than on the setup's name, and the plan
      // is re-worked out on every dock and every settings write. If a re-apply
      // of the SAME answer cleared it, a workspace someone moved would be
      // dragged back the next time anything touched a config file.
      await core.apply(ApplyReason.startup);
      sway.userSwitchedTo(3, 'DP-4');
      await settle();
      sway.focused = 3;
      expect(core.noteMove(3, 'DP-4'), isTrue,
          reason: 'workspace 3 belongs on the laptop panel, not on DP-4');
      await core.apply(ApplyReason.configChanged);
      sway.commands.clear();
      sway.userSwitchedTo(3, 'DP-4');
      await settle();
      expect(sway.commands, isEmpty);
    });

    test('sway discarding its workspace configs is answered', () async {
      // `swaymsg reload` throws our bindings away with everything else. It
      // is not something to recommend — measured, it also wipes every output
      // position and scale — but a user or a keybinding can still run it, and
      // the helper has to notice.
      sway.reload();
      await settle();
      expect(sway.commands, hasLength(1));
    });
  });
}
