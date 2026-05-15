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
      // Binding form is "workspace N output X" without the `number`
      // keyword — see buildSwayWorkspaceChain doc for why.
      for (final ws in [1, 4, 7]) {
        expect(out, contains("workspace $ws output 'L'"));
      }
      for (final ws in [2, 5, 8]) {
        expect(out, contains("workspace $ws output 'M'"));
      }
      for (final ws in [3, 6, 9]) {
        expect(out, contains("workspace $ws output 'R'"));
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
        expect(out, contains("workspace $ws output 'Left'"));
      }
      for (final ws in [2, 4, 6, 8]) {
        expect(out, contains("workspace $ws output 'Right'"));
      }
    });

    test(
        'mirror destinations excluded from chained workspace-exec line',
        () {
      // Same coverage as the test above but scoped to JUST the chained
      // `exec swaymsg "..."` line, sidestepping the per-output `output
      // 'B' enable …` line that is supposed to mention B.
      final p = Profile(
        name: 'Mirror',
        monitors: [
          _mon(id: 'A', x: 0),
          _mon(id: 'B', x: 1920, mirrorOf: 'A'),
        ],
      );
      final out = KanshiConfigWriter.render(
        [p],
        options: KanshiWriteOptions.swayDefaults,
      );
      final chain = out
          .split('\n')
          .firstWhere((l) => l.contains('exec swaymsg'));
      // Every workspace declaration AND every move command must
      // target A only.
      for (var ws = 1; ws <= 9; ws++) {
        expect(chain, contains("workspace $ws output 'A'"));
      }
      expect(chain, isNot(contains("output 'B'")),
          reason: 'No workspace-target reference to B in the chain.');
      expect(chain, isNot(contains("move workspace to output 'B'")),
          reason: 'No active move targeting B in the chain.');
    });

    test('mirror destinations are positioned at the source\'s coordinates',
        () {
      // wl-mirror keeps painting the destination's pixels (it targets
      // by output name, not by position), but Sway still treats the
      // destination as its own interactive area with its own cursor
      // routing. Stacking the rectangles in Sway's coord space
      // eliminates the dead zone the user can otherwise wander into.
      final p = Profile(
        name: 'Mirror',
        monitors: [
          _mon(id: 'A', x: 0, y: 0),
          _mon(id: 'B', x: 1920, y: 0, mirrorOf: 'A'),
        ],
      );
      final out = KanshiConfigWriter.render(
        [p],
        options: KanshiWriteOptions.neutral,
      );
      // Both A and B share position 0,0 — B's own x=1920 is overridden.
      expect(out, contains("output 'A' enable"));
      expect(out, contains("output 'B' enable"));
      expect(out, contains("position 0,0"));
      expect(out, isNot(contains("position 1920,0")),
          reason: "Mirror destination must not retain its own x; it "
              "borrows the source's position so Sway has no input "
              "dead-zone.");
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
      expect(out, contains("workspace 1 output 'R'"));
      expect(out, contains("workspace 2 output 'L'"));
      expect(out, contains("workspace 3 output 'R'"));
      expect(out, contains("workspace 4 output 'L'"));
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

  group('buildSwayWorkspaceChain', () {
    test('returns null for an empty rank list', () {
      expect(buildSwayWorkspaceChain(const []), isNull);
    });

    test('emits the same chain the writer embeds', () {
      // Independent regression on the extracted helper: the embedded
      // chain in the writer must be byte-identical to a direct call
      // with the same ranks.
      final p = Profile(
        name: 'Desk',
        monitors: [
          _mon(id: 'A', x: 0),
          _mon(id: 'B', x: 1920),
        ],
      );
      final rendered = KanshiConfigWriter.render(
        [p],
        options: KanshiWriteOptions.swayDefaults,
      );
      final embedded = rendered
          .split('\n')
          .firstWhere((l) => l.contains('exec swaymsg'));
      // Strip the wrapping `    exec swaymsg "` and trailing `"`.
      final inner = embedded
          .trim()
          .replaceFirst('exec swaymsg "', '')
          .replaceFirst(RegExp(r'"$'), '');
      final ranked = resolveWorkspaceRanks([
        _mon(id: 'A', x: 0),
        _mon(id: 'B', x: 1920),
      ]);
      expect(buildSwayWorkspaceChain(ranked), equals(inner));
    });

    test('three monitors interleave 1/4/7, 2/5/8, 3/6/9 left to right', () {
      final ranked = resolveWorkspaceRanks([
        _mon(id: 'L', x: 0),
        _mon(id: 'M', x: 1920),
        _mon(id: 'R', x: 3840),
      ]);
      final chain = buildSwayWorkspaceChain(ranked)!;
      // Pre-anchor declarations: every workspace rank lands on the
      // expected output. Binding form is "workspace N output X"
      // (without `number`) so sway stores a persistent assignment
      // keyed by workspace name — see the chain docstring.
      for (final ws in [1, 4, 7]) {
        expect(chain, contains("workspace $ws output 'L'"));
      }
      for (final ws in [2, 5, 8]) {
        expect(chain, contains("workspace $ws output 'M'"));
      }
      for (final ws in [3, 6, 9]) {
        expect(chain, contains("workspace $ws output 'R'"));
      }
      // The number-less binding form must NOT also emit the `number`
      // variant; the latter is what we found to be a no-op on sway 1.11.
      expect(chain, isNot(contains("workspace number 1 output 'L'")));
      // Ends on workspace 1 to land focus on the leftmost output.
      expect(chain.split('; ').last, equals('workspace number 1'));
    });

    test(
        'phase-1 declares persistent bindings via "workspace N" and phase-2 '
        'force-moves via "workspace number N"', () {
      final ranked = resolveWorkspaceRanks([
        _mon(id: 'L', x: 0),
        _mon(id: 'R', x: 1920),
      ]);
      final chain = buildSwayWorkspaceChain(ranked, maxWorkspaces: 2)!;
      final stmts = chain.split('; ');
      // Phase 1 (the maxWorkspaces bindings) comes first, NO `number`.
      expect(stmts[0], equals("workspace 1 output 'L'"));
      expect(stmts[1], equals("workspace 2 output 'R'"));
      // Phase 2 then pairs `workspace number N` (focus by numeric
      // slot, rename-safe) with a `move workspace to output 'X'` for
      // force-moves on any pre-existing workspaces.
      expect(stmts[2], equals('workspace number 1'));
      expect(stmts[3], equals("move workspace to output 'L'"));
      expect(stmts[4], equals('workspace number 2'));
      expect(stmts[5], equals("move workspace to output 'R'"));
      // Trailing focus lands the user on workspace 1.
      expect(stmts.last, equals('workspace number 1'));
    });

    test('respects the provided maxWorkspaces ceiling', () {
      final ranked = resolveWorkspaceRanks([_mon(id: 'A', x: 0)]);
      final chain = buildSwayWorkspaceChain(ranked, maxWorkspaces: 3)!;
      // Pass 1: 3 pre-anchors. Pass 2: 3 × (focus + move) = 6.
      // Plus the trailing `workspace number 1` focus = 10 statements.
      expect(chain.split('; ').length, equals(3 + 2 * 3 + 1));
      expect(chain, isNot(contains('workspace number 4')));
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
      // Mirror persistence has two parts that must agree:
      //   1) the `# kanshi_gui:mirror` annotation (parser → `mirrorOf`)
      //   2) a `pgrep`-guarded `exec wl-mirror` so kanshi spawns the
      //      mirror at session start when the GUI isn't running yet.
      // The guard is what makes this safe against `kanshictl reload`
      // (a bare exec would stack duplicate wl-mirror processes).
      expect(rendered, contains("# kanshi_gui:mirror 'B'='A'"),
          reason: 'Mirror state is persisted as an annotation.');
      expect(rendered, contains('pgrep -f "wl-mirror --fullscreen-output B"'),
          reason: 'Boot-time exec must guard against duplicate spawns.');
      expect(
          rendered,
          contains(
              'wl-mirror --fullscreen-output "B" "A"'),
          reason: 'Guarded fallback spawns the mirror when none is running.');

      final reparsed =
          KanshiConfigParser.parse(rendered).single.monitors;
      final a = reparsed.firstWhere((m) => m.id == 'A');
      final b = reparsed.firstWhere((m) => m.id == 'B');
      expect(a.mirrorOf, isNull,
          reason: 'Source tile is unaffected by the annotation.');
      expect(b.mirrorOf, equals('A'),
          reason: 'Destination tile must recover its mirror target.');
    });

    test('guarded mirror exec is idempotent across kanshi reloads', () {
      // Verify the structural guarantee: every mirror destination gets
      // exactly one exec line, and the pgrep check pins on the
      // destination's specific `--fullscreen-output` argv. Two mirrors
      // in the same profile must produce two independent guards.
      final p = Profile(
        name: 'TwoMirrors',
        monitors: [
          _mon(id: 'A', x: 0, y: 0),
          _mon(id: 'B', x: 1920, y: 0, mirrorOf: 'A'),
          _mon(id: 'C', x: 3840, y: 0, mirrorOf: 'A'),
        ],
      );
      final rendered = KanshiConfigWriter.render(
        [p],
        options: KanshiWriteOptions.swayDefaults,
      );
      final execLines = rendered
          .split('\n')
          .where((l) => l.contains('wl-mirror'))
          .toList();
      expect(execLines, hasLength(2),
          reason: 'One exec per mirror destination, no more.');
      expect(execLines[0], contains('--fullscreen-output B'));
      expect(execLines[1], contains('--fullscreen-output C'));
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

    test('manufacturer with apostrophe round-trips losslessly', () {
      // Pre-1.5.1 the writer stripped apostrophes from manufacturer
      // before emitting, but the matcher byte-compared against the
      // unstripped live data — so a `L'Hôtel Display` would silently
      // fall out of manufacturer-fallback matching after a save/load.
      // The fix escapes the apostrophe as `\'` and unescapes on read.
      final p = Profile(
        name: 'Apostrophe',
        monitors: [
          MonitorTileData(
            id: 'HDMI-A-1',
            manufacturer: "L'Hôtel Display",
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
      expect(rendered, contains(r"\'Hôtel Display"),
          reason: 'On-disk form must escape apostrophes, not strip '
              'them, otherwise matching against live data lossily '
              'differs by one byte.');
      expect(rendered, isNot(contains("'L'Hôtel")),
          reason: 'Bare unescaped apostrophe inside the value would '
              'break the parser regex by closing the quote early.');
      final reparsed = KanshiConfigParser.parse(rendered);
      final m = reparsed.single.monitors.single;
      expect(m.manufacturer, equals("L'Hôtel Display"),
          reason: 'After unescape, the in-memory value is bit-identical '
              'to what live sway/wlr-randr would emit.');
    });

    test('apostrophe-free manufacturer still round-trips', () {
      // Sanity: the new escape-aware parser must not regress the
      // common case where manufacturer has no apostrophes.
      final p = Profile(
        name: 'Plain',
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
      final reparsed = KanshiConfigParser.parse(rendered);
      expect(
          reparsed.single.monitors.single.manufacturer,
          equals('BenQ Projector ABC123'));
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
