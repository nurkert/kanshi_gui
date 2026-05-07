import 'package:flutter_test/flutter_test.dart';
import 'package:kanshi_gui/models/monitor_tile_data.dart';
import 'package:kanshi_gui/models/profiles.dart';
import 'package:kanshi_gui/services/kanshi_config_parser.dart';
import 'package:kanshi_gui/services/kanshi_config_writer.dart';

MonitorTileData _mon({
  String id = 'M',
  double x = 0,
  double y = 0,
  double w = 1920,
  double h = 1080,
  double scale = 1.0,
  bool enabled = true,
  int rotation = 0,
  double refresh = 60,
  String? mirrorOf,
  int? workspaceRank,
}) {
  return MonitorTileData(
    id: id,
    manufacturer: id,
    x: x,
    y: y,
    width: w,
    height: h,
    scale: scale,
    rotation: rotation,
    refresh: refresh,
    resolution: '${w.toInt()}x${h.toInt()}',
    orientation: w >= h ? 'landscape' : 'portrait',
    enabled: enabled,
    mirrorOf: mirrorOf,
    workspaceRank: workspaceRank,
  );
}

void main() {
  group('KanshiConfigWriter.render — neutral defaults', () {
    test('does not emit Sway-specific exec lines by default', () {
      final p = Profile(name: 'X', monitors: [_mon(id: 'A')]);
      final out = KanshiConfigWriter.render([p]);
      expect(out, isNot(contains('exec swaymsg')));
      expect(out, isNot(contains('current_kanshi_profile')));
    });

    test('renders an enabled output with the expected fields', () {
      final p = Profile(name: 'Desk', monitors: [_mon(id: 'eDP-1')]);
      final out = KanshiConfigWriter.render([p]);
      expect(out, contains("profile 'Desk' {"));
      expect(out,
          contains("output 'eDP-1' enable scale 1.00 mode 1920x1080@60Hz "
              "transform normal position 0,0"));
    });

    test('emits `disable` line for disabled outputs', () {
      final p = Profile(
        name: 'X',
        monitors: [_mon(id: 'eDP-1', enabled: false)],
      );
      final out = KanshiConfigWriter.render([p]);
      expect(out, contains("output 'eDP-1' disable"));
    });

    test('skips profiles without monitors', () {
      final out = KanshiConfigWriter.render([Profile(name: 'X', monitors: [])]);
      expect(out.trim(), isEmpty);
    });
  });

  group('KanshiConfigWriter.render — Sway extras', () {
    test('emits workspace exec lines when injectSwayWorkspaceExec is true', () {
      final p = Profile(
        name: 'P',
        monitors: [_mon(id: 'A'), _mon(id: 'B', x: 1920)],
      );
      final out = KanshiConfigWriter.render(
        [p],
        options: KanshiWriteOptions.swayDefaults,
      );
      expect(out, contains('exec swaymsg'));
      expect(out, contains("current_kanshi_profile"));
    });

    test('interleaves workspaces left-to-right across three monitors', () {
      final p = Profile(
        name: 'Triple',
        monitors: [
          _mon(id: 'L', x: 0),
          _mon(id: 'M', x: 1920),
          _mon(id: 'R', x: 3840),
        ],
      );
      final out = KanshiConfigWriter.render(
        [p],
        options: KanshiWriteOptions.swayDefaults,
      );
      // Leftmost L owns 1/4/7, middle M owns 2/5/8, rightmost R owns 3/6/9.
      for (final ws in [1, 4, 7]) {
        expect(out, contains("workspace number $ws output 'L'"));
      }
      for (final ws in [2, 5, 8]) {
        expect(out, contains("workspace number $ws output 'M'"));
      }
      for (final ws in [3, 6, 9]) {
        expect(out, contains("workspace number $ws output 'R'"));
      }
    });

    test('two-monitor layout interleaves odd/even', () {
      final p = Profile(
        name: 'Pair',
        monitors: [
          _mon(id: 'Left', x: 0),
          _mon(id: 'Right', x: 1920),
        ],
      );
      final out = KanshiConfigWriter.render(
        [p],
        options: KanshiWriteOptions.swayDefaults,
      );
      // Left screen: 1/3/5/7/9, Right screen: 2/4/6/8.
      for (final ws in [1, 3, 5, 7, 9]) {
        expect(out, contains("workspace number $ws output 'Left'"));
      }
      for (final ws in [2, 4, 6, 8]) {
        expect(out, contains("workspace number $ws output 'Right'"));
      }
    });

    test('explicit workspaceRank overrides X-derived rank', () {
      final p = Profile(
        name: 'Override',
        monitors: [
          // Physically L is at x=0, R is at x=1920. Without override the
          // left screen would own odd workspaces. We pin L to rank 1
          // (right slot) so R becomes rank 0 and owns the odds.
          _mon(id: 'L', x: 0, workspaceRank: 1),
          _mon(id: 'R', x: 1920),
        ],
      );
      final out = KanshiConfigWriter.render(
        [p],
        options: KanshiWriteOptions.swayDefaults,
      );
      expect(out, contains("# kanshi_gui:rank 'L'=1"));
      expect(out, contains("workspace number 1 output 'R'"));
      expect(out, contains("workspace number 2 output 'L'"));
      expect(out, contains("workspace number 3 output 'R'"));
      expect(out, contains("workspace number 4 output 'L'"));
    });

    test(
        'workspace assignment is one chained swaymsg call with explicit '
        'move-to-output for each workspace', () {
      // Two coupled bugs forced this design:
      //
      //  1. Multiple `exec swaymsg "..."` lines race because kanshi
      //     spawns each in its own fork/exec; sway processes them
      //     out-of-order. ONE chained invocation eliminates the race.
      //
      //  2. `workspace N output X` is passive — it sets the home for
      //     newly-created workspaces but does NOT relocate ones that
      //     already exist with windows. The user dockted with a window
      //     on workspace 1 (laptop-only), then the docking layout
      //     wasn't applied retroactively. Adding `workspace N; move
      //     workspace to output X` actively moves existing workspaces.
      final p = Profile(
        name: 'Triple',
        monitors: [
          _mon(id: 'L', x: 0),
          _mon(id: 'M', x: 1920),
          _mon(id: 'R', x: 3840),
        ],
      );
      final out = KanshiConfigWriter.render(
        [p],
        options: KanshiWriteOptions.swayDefaults,
      );
      // Exactly one `exec swaymsg` line in the workspace-assignment
      // section. (The current-profile-marker uses `exec echo`, not
      // swaymsg, so it doesn't count toward this assertion.)
      final swayMsgLines =
          out.split('\n').where((l) => l.contains('exec swaymsg')).toList();
      expect(swayMsgLines, hasLength(1),
          reason: 'Multiple exec swaymsg lines reintroduce the race that '
              'leaked windows onto the wrong output during docking.');
      final chained = swayMsgLines.single;
      // Active relocation must be present for each workspace 1..9.
      // Crucially we use `workspace number N` (not `workspace N`):
      // bare `workspace N` would treat N as the workspace *name*, so
      // a user with a named workspace like "1: code" would silently
      // get a fresh empty "1" workspace alongside their existing one.
      // The `number` keyword targets the numeric slot regardless of
      // human-readable name.
      for (var ws = 1; ws <= 9; ws++) {
        expect(chained, contains("workspace number $ws"),
            reason: 'Workspace $ws focus must use `number` to disambiguate '
                'from any user-assigned workspace name.');
        expect(chained, contains("move workspace to output"),
            reason: 'Existing workspaces must be actively relocated.');
      }
      // Final command lands focus on workspace number 1 — leftmost
      // rank, typically the user's primary screen after docking.
      expect(chained.trimRight().endsWith('workspace number 1"'), isTrue,
          reason: 'Chain must end on `workspace number 1` to give the '
              'user a predictable focus landing instead of dropping them '
              'on ws 9.');
    });

    test('round-trips workspaceRank through writer → parser', () {
      final p = Profile(
        name: 'Roundtrip',
        monitors: [
          _mon(id: 'A', x: 0, workspaceRank: 2),
          _mon(id: 'B', x: 1920),
          _mon(id: 'C', x: 3840, workspaceRank: 0),
        ],
      );
      final rendered = KanshiConfigWriter.render(
        [p],
        options: KanshiWriteOptions.swayDefaults,
      );
      final reparsed = KanshiConfigParser.parse(rendered).single.monitors;
      final a = reparsed.firstWhere((m) => m.id == 'A');
      final c = reparsed.firstWhere((m) => m.id == 'C');
      expect(a.workspaceRank, equals(2));
      expect(c.workspaceRank, equals(0));
    });
  });

  group('Round-trip: writer → parser', () {
    test('preserves monitor count and properties for a 2-monitor profile', () {
      final p = Profile(
        name: 'Desk',
        monitors: [
          _mon(id: 'A', x: 0, y: 0, w: 2560, h: 1440),
          _mon(id: 'B', x: 2560, y: 0, w: 1920, h: 1080, scale: 1.5),
        ],
      );
      final rendered = KanshiConfigWriter.render([p]);
      final reparsed = KanshiConfigParser.parse(rendered);

      expect(reparsed, hasLength(1));
      expect(reparsed.first.name, equals('Desk'));
      expect(reparsed.first.monitors, hasLength(2));
      expect(reparsed.first.monitors.map((m) => m.id).toSet(),
          equals({'A', 'B'}));

      final b =
          reparsed.first.monitors.firstWhere((m) => m.id == 'B');
      expect(b.scale, equals(1.5));
    });

    test('round-trips a rotated portrait monitor', () {
      final p = Profile(
        name: 'Vert',
        monitors: [_mon(id: 'A', w: 2560, h: 1440, rotation: 90)],
      );
      final rendered = KanshiConfigWriter.render([p]);
      final m = KanshiConfigParser.parse(rendered).single.monitors.single;
      expect(m.rotation, equals(90));
      expect(m.width, equals(1440));
      expect(m.height, equals(2560));
    });

    test('mirror state survives writer→parser when sway extras are on', () {
      final p = Profile(
        name: 'Mirror',
        monitors: [
          _mon(id: 'A', x: 0, y: 0, w: 2560, h: 1440),
          _mon(id: 'B', x: 2560, y: 0, mirrorOf: 'A'),
        ],
      );
      final rendered = KanshiConfigWriter.render(
        [p],
        options: KanshiWriteOptions.swayDefaults,
      );
      // Mirror persistence is a `# kanshi_gui:mirror` comment, NOT an
      // `exec wl-mirror` line: the latter caused kanshi to spawn a
      // duplicate wl-mirror process on every reload, fighting the
      // GUI's MirrorRunner for ownership.
      expect(rendered, contains("# kanshi_gui:mirror 'B'='A'"),
          reason: 'Mirror state is persisted as an annotation now.');
      expect(rendered, isNot(contains('exec wl-mirror')),
          reason: 'No exec hook → no duplicate wl-mirror processes.');

      final reparsed =
          KanshiConfigParser.parse(rendered).single.monitors;
      final a = reparsed.firstWhere((m) => m.id == 'A');
      final b = reparsed.firstWhere((m) => m.id == 'B');
      expect(a.mirrorOf, isNull,
          reason: 'Source tile is unaffected by the annotation.');
      expect(b.mirrorOf, equals('A'),
          reason: 'Destination tile must recover its mirror target.');
    });

    test('neutral options do not emit wl-mirror exec lines', () {
      final p = Profile(
        name: 'NoExtras',
        monitors: [
          _mon(id: 'A', x: 0, y: 0),
          _mon(id: 'B', x: 1920, y: 0, mirrorOf: 'A'),
        ],
      );
      final rendered = KanshiConfigWriter.render([p]);
      expect(rendered, isNot(contains('wl-mirror')));
    });

    test('manufacturer survives writer→parser via the EDID annotation', () {
      // Without the `# kanshi_gui:edid` annotation the parser had no
      // signal for manufacturer (it falls back to `manufacturer = id`),
      // so a profile saved with a known beamer's EDID would match by
      // port id only — re-plugging the beamer into a different port
      // would leak it from the matcher. The annotation closes that gap.
      final p = Profile(
        name: 'Beamer',
        monitors: [
          MonitorTileData(
            id: 'HDMI-A-1',
            manufacturer: 'BenQ Projector ABC123',
            x: 0,
            y: 0,
            width: 1920,
            height: 1080,
            scale: 1.0,
            rotation: 0,
            refresh: 60,
            resolution: '1920x1080',
            orientation: 'landscape',
          ),
        ],
      );
      final rendered = KanshiConfigWriter.render([p]);
      expect(rendered,
          contains("# kanshi_gui:edid 'HDMI-A-1'='BenQ Projector ABC123'"),
          reason: 'EDID-derived manufacturer is the only thing that ties a '
              'profile to a physical device across port reassignment.');
      final reparsed = KanshiConfigParser.parse(rendered);
      final m = reparsed.single.monitors.single;
      expect(m.manufacturer, equals('BenQ Projector ABC123'));
    });

    test('writer skips the EDID annotation when manufacturer == id', () {
      // Hand-edited configs — and old configs round-tripped before the
      // annotation existed — set manufacturer to the port id by
      // default. Emitting `# kanshi_gui:edid 'eDP-1'='eDP-1'` would be
      // pure noise and clutter the config.
      final p = Profile(name: 'X', monitors: [_mon(id: 'eDP-1')]);
      final out = KanshiConfigWriter.render([p]);
      expect(out, isNot(contains('kanshi_gui:edid')));
    });

    test('parser tolerates bare-id wl-mirror exec lines', () {
      // Hand-written / non-GUI configs may omit single quotes.
      const raw = '''
profile 'Hand' {
    output 'A' enable scale 1.00 mode 1920x1080@60Hz transform normal position 0,0
    output 'B' enable scale 1.00 mode 1920x1080@60Hz transform normal position 1920,0
    exec wl-mirror A --fullscreen-output B --fullscreen &
}
''';
      final mons = KanshiConfigParser.parse(raw).single.monitors;
      final b = mons.firstWhere((m) => m.id == 'B');
      expect(b.mirrorOf, equals('A'));
    });
  });
}
