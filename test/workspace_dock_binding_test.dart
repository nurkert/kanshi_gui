import 'package:flutter_test/flutter_test.dart';
import 'package:kanshi_gui/domain/workspace_plan.dart';
import 'package:kanshi_gui/models/monitor_tile_data.dart';
import 'package:kanshi_gui/models/profiles.dart';
import 'package:kanshi_gui/services/app_settings.dart';
import 'package:kanshi_gui/services/kanshi_config_writer.dart';
import 'package:kanshi_gui/services/workspace_daemon_core.dart';

import 'fakes/fake_sway.dart';

/// The bug a docked laptop had, and the reason it looked like the config file
/// was being ignored.
///
/// Reported from a real desk: three screens, the numbers 1/4/7 left, 2/5/8
/// middle, 3/6/9 right — and workspace 2 kept opening on the laptop panel on
/// the far right, while the middle screen only ever showed workspace 8.
///
/// Nothing was wrong with the file. sway's `cmd_workspace` APPENDS to a
/// workspace's output list and never clears it, and
/// `workspace_get_initial_output` takes the first entry that resolves to a
/// connected screen. Boot undocked and kanshi activates the laptop-only setup,
/// which binds all nine workspaces to the panel. Dock, kanshi switches setups
/// and binds them to the external screens — appended BEHIND the panel, which
/// is still connected. Every workspace opened from then on is born on the
/// laptop panel for the rest of the session, and re-declaring is a no-op.
///
/// Measured on sway 1.12, along with the reason the obvious cure is not one:
/// `swaymsg reload` does discard the workspace configs, and it also throws
/// away every output position and scale the compositor was given and
/// re-arranges the desk from scratch.
MonitorTileData _mon(String id, String descriptor, double x) =>
    MonitorTileData(
      id: id,
      manufacturer: descriptor,
      edidDescriptor: descriptor,
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

/// The user's real desk, left to right.
final _left = _mon('DP-4', 'Samsung LS27D60xU HK2XA01318', 0);
final _middle = _mon('DP-5', 'Samsung LS27D60xU HK2XA01167', 2560);
final _panel = _mon('eDP-1', 'InfoVision 0x057D Unknown', 5120);

Profile _docked() => Profile(
      name: 'Office - Titan Rain',
      monitors: [_left, _middle, _panel],
    );

Profile _laptopOnly() => Profile(
      name: 'T480',
      monitors: [_mon('eDP-1', 'InfoVision 0x057D Unknown', 0)],
    );

void main() {
  group('a binding outlives the desk it was written for', () {
    test('the old one-screen-per-workspace form loses the dock', () async {
      // The shape every release up to this one wrote: one target per
      // workspace, per setup. Played through a sway that appends bindings the
      // way the real one does.
      final sway = FakeSway(live: [_left, _middle, _panel]);
      // Boot undocked: the laptop-only setup claims all nine.
      for (var ws = 1; ws <= 9; ws++) {
        await sway.run("workspace $ws output 'InfoVision 0x057D Unknown'");
      }
      // Dock: the three-screen setup claims them again.
      await sway.run("workspace 2 output 'Samsung LS27D60xU HK2XA01167'");

      sway.userSwitchedTo(2);
      expect(
        sway.workspaceOutputs(),
        completion(containsPair(2, 'eDP-1')),
        reason: 'this is the bug: the file says DP-5 and sway says the panel',
      );
    });

    test('the preference list survives it', () async {
      final sway = FakeSway(live: [_left, _middle, _panel]);
      final homes = workspaceHomes(
        profiles: [_docked(), _laptopOnly()],
        distribution: WorkspaceDistribution.interleaved,
      );
      // Declared undocked and declared again docked — the identical list both
      // times, which is what makes appending it harmless.
      for (final line in buildWorkspaceDeclarations(homes)!.split(';')) {
        await sway.run(line.trim());
      }
      for (final line in buildWorkspaceDeclarations(homes)!.split(';')) {
        await sway.run(line.trim());
      }

      sway.userSwitchedTo(2);
      sway.userSwitchedTo(5);
      sway.userSwitchedTo(8);
      final live = await sway.workspaceOutputs();
      expect(live[2], 'DP-5');
      expect(live[5], 'DP-5');
      expect(live[8], 'DP-5',
          reason: 'the middle screen gets 2, 5 and 8 — not only 8');
    });

    test('and it still lands on the panel when nothing else is plugged in',
        () async {
      final undocked = _mon('eDP-1', 'InfoVision 0x057D Unknown', 0);
      final sway = FakeSway(live: [undocked]);
      final homes = workspaceHomes(
        profiles: [_docked(), _laptopOnly()],
        distribution: WorkspaceDistribution.interleaved,
      );
      for (final line in buildWorkspaceDeclarations(homes)!.split(';')) {
        await sway.run(line.trim());
      }
      sway.userSwitchedTo(2);
      expect(await sway.workspaceOutputs(), containsPair(2, 'eDP-1'));
    });
  });

  group('workspaceHomes', () {
    test('names every screen a workspace could belong to, biggest desk first',
        () {
      final homes = workspaceHomes(
        profiles: [_laptopOnly(), _docked()],
        distribution: WorkspaceDistribution.interleaved,
      );
      expect(
        homes[2]!.map((c) => c.value).toList(),
        ['Samsung LS27D60xU HK2XA01167', 'InfoVision 0x057D Unknown'],
        reason: 'config order is the tie-break, screen count is not',
      );
    });

    test('the same list whatever is plugged in', () {
      // The one property the whole scheme rests on. A list that depended on
      // the live outputs would stack a different order on every dock and put
      // us straight back where we started.
      final a = workspaceHomes(
        profiles: [_docked(), _laptopOnly()],
        distribution: WorkspaceDistribution.interleaved,
      );
      final b = workspaceHomes(
        profiles: [_docked(), _laptopOnly()],
        distribution: WorkspaceDistribution.interleaved,
      );
      expect(a.map((k, v) => MapEntry(k, v.map((c) => c.value).toList())),
          b.map((k, v) => MapEntry(k, v.map((c) => c.value).toList())));
    });

    test('a screen named twice is named once', () {
      final homes = workspaceHomes(
        profiles: [_laptopOnly(), _laptopOnly()],
        distribution: WorkspaceDistribution.interleaved,
      );
      expect(homes[1], hasLength(1));
    });

    test('addressed by EDID, because an absent screen has no connector', () {
      final homes = workspaceHomes(
        profiles: [_docked()],
        distribution: WorkspaceDistribution.interleaved,
      );
      expect(homes[1]!.single.value, 'Samsung LS27D60xU HK2XA01318');
      expect(homes[1]!.single.isDescription, isTrue,
          reason: 'the connector a dock hands out is not stable; the EDID is');
    });

    test('placement switched off says nothing at all', () {
      expect(workspaceHomes(profiles: [_docked()], distribution: null), isEmpty);
    });

    test('a mirror destination is never given workspaces of its own', () {
      final withMirror = Profile(name: 'Mirrored', monitors: [
        _left,
        _middle.copyWith(mirrorOf: 'DP-4'),
      ]);
      final homes = workspaceHomes(
        profiles: [withMirror],
        distribution: WorkspaceDistribution.interleaved,
      );
      expect(homes.values.expand((l) => l).map((c) => c.value).toSet(),
          {'Samsung LS27D60xU HK2XA01318'});
    });
  });

  group('the file the app writes', () {
    test('every setup carries the same nine bindings', () {
      final rendered = KanshiConfigWriter.render(
        [_docked(), _laptopOnly()],
        options: KanshiWriteOptions.swayDefaults,
      );
      final blocks = rendered.split('profile ').where((b) => b.isNotEmpty);
      expect(blocks, hasLength(2));
      final execs = [
        for (final b in blocks)
          b
              .split('\n')
              .where((l) => l.contains('exec swaymsg workspace'))
              .map((l) => l.trim())
              .toList(),
      ];
      expect(execs.first, equals(execs.last),
          reason: 'a per-setup binding is the trap; sway keeps only the first');
      expect(
        execs.first[1],
        'exec swaymsg workspace 2 output '
            '\'"Samsung LS27D60xU HK2XA01167"\' '
            '\'"InfoVision 0x057D Unknown"\'',
        reason: 'workspace 2: the middle screen, then the panel as a fallback',
      );
    });
  });

  group('and when the session already has the stale binding in it', () {
    // A session that started before this version cannot be fixed by
    // declaring: the stale entry is first and sway will not forget it short
    // of a logout. This is the half that repairs it live.
    late FakeSway sway;
    late WorkspaceDaemonCore core;

    setUp(() async {
      sway = FakeSway(live: [_left, _middle, _panel]);
      core = WorkspaceDaemonCore(
        sway: sway,
        env: FakeEnvironment(
          mode: WorkspaceManagementMode.interleaved,
          knownProfiles: [_docked(), _laptopOnly()],
        ),
      );
      sway.events().listen((e) {
        final v = classifySwayEvent(e);
        if (v.action != SwayEventAction.correct) return;
        core.noteFocus(v.workspace!);
        core.serialised(() => core.correct(v.workspace!, v.output!));
      });
      await core.apply(ApplyReason.startup);
      sway.commands.clear();
    });

    Future<void> settle() async {
      for (var i = 0; i < 40; i++) {
        await Future<void>.delayed(Duration.zero);
      }
    }

    test('switching to a workspace on the wrong screen puts it right',
        () async {
      sway.userSwitchedTo(2, 'eDP-1');
      await settle();
      expect(sway.commands.single,
          "move workspace to output 'Samsung LS27D60xU HK2XA01167'");
      expect(await sway.workspaceOutputs(), containsPair(2, 'DP-5'));
    });

    test('and does not do it twice', () async {
      sway.userSwitchedTo(2, 'eDP-1');
      await settle();
      sway.userSwitchedTo(2, 'DP-5');
      await settle();
      expect(sway.commands, hasLength(1));
    });

    test('a workspace that is already home is left alone', () async {
      sway.userSwitchedTo(2, 'DP-5');
      await settle();
      expect(sway.commands, isEmpty);
    });

    test('a correction cannot answer itself', () async {
      // The whole reason this is allowed to exist. A bare
      // `move workspace to output` emits `move`, and an `init` for the
      // workspace sway auto-creates on the screen just vacated — and no
      // `focus`. Measured on sway 1.12; modelled in FakeSway.
      for (var ws = 1; ws <= 9; ws++) {
        sway.userSwitchedTo(ws, 'eDP-1');
        await settle();
      }
      expect(sway.commands, hasLength(6),
          reason: 'six wrong workspaces, six moves — 3, 6 and 9 belong on the '
              'panel and were already there — and nothing after them');
    });

    test('a workspace the user is no longer on is not dragged around',
        () async {
      // The chain focuses all nine on its way through. Every one of those
      // focus events describes a workspace it is about to move itself.
      sway.userSwitchedTo(2, 'eDP-1');
      sway.userSwitchedTo(3, 'eDP-1');
      await settle();
      expect(sway.commands, isEmpty,
          reason: 'workspace 3 belongs on the panel, and 2 is stale');
    });

    test('placement switched off means the correction stops too', () async {
      (core.env as FakeEnvironment).mode = WorkspaceManagementMode.off;
      await core.apply(ApplyReason.configChanged);
      sway.commands.clear();
      sway.userSwitchedTo(2, 'eDP-1');
      await settle();
      expect(sway.commands, isEmpty);
    });
  });
}
