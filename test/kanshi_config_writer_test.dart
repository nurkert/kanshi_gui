import 'package:flutter_test/flutter_test.dart';
import 'package:kanshi_gui/models/monitor_tile_data.dart';
import 'package:kanshi_gui/models/profiles.dart';
import 'package:kanshi_gui/services/kanshi_config_parser.dart';
import 'package:kanshi_gui/services/kanshi_config_writer.dart';
import 'package:kanshi_gui/services/layout_math.dart';

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
        expect(out, contains('workspace $ws output \'"L"\''));
      }
      for (final ws in [2, 5, 8]) {
        expect(out, contains('workspace $ws output \'"M"\''));
      }
      for (final ws in [3, 6, 9]) {
        expect(out, contains('workspace $ws output \'"R"\''));
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
        expect(out, contains('workspace $ws output \'"Left"\''));
      }
      for (final ws in [2, 4, 6, 8]) {
        expect(out, contains('workspace $ws output \'"Right"\''));
      }
    });

    test('mirror destinations excluded from chained workspace-exec line', () {
      // Mirror dests don't own any of the numeric 1..9 workspaces —
      // those go to the source and other non-mirror outputs. Earlier
      // attempts to ALSO emit a named `mirror (<dst>)` claim leaked an
      // unreachable "mirror (B)" label into the user's swaybar; we
      // removed it because the orphan workspace is handled by the
      // controller's chain re-run in `_verifyAndFixWorkspacePlacement`
      // (the chain visits every numeric ws, which displaces any orphan
      // visible on the dest and sway garbage-collects it once empty).
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
      final execs = out
          .split('\n')
          .where((l) => l.contains('exec swaymsg'))
          .map((l) => l.trim())
          .toList();
      for (var ws = 1; ws <= 9; ws++) {
        expect(execs, contains('exec swaymsg workspace $ws output \'"A"\''));
      }
      expect(execs.join('\n'), isNot(contains('"B"')),
          reason: 'A mirror destination shows another screen and gets no '
              'workspaces of its own.');
      expect(out, isNot(contains("mirror (B)")),
          reason: 'No named-claim leakage into the user-visible bar.');
    });

    test('mirror destinations keep their own non-overlapping position', () {
      // The 1.5.7 position-stack trick (dest borrows src's coords)
      // backfires when wl-mirror is actually running: sway paints
      // wl-mirror's fullscreen surface onto every output whose geometry
      // overlaps the dest's rect — including the source — and wl-mirror
      // then captures the source's now-self-containing image. Classic
      // infinity mirror. Dest MUST occupy a different rectangle than
      // src so the surface stays exclusively on the dest output.
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
      expect(out, contains("output 'A' enable"));
      expect(out, contains("output 'B' enable"));
      expect(out, contains("position 1920,0"),
          reason: "Mirror destination MUST stay at its own x — sharing "
              "the source's rect makes wl-mirror's surface bleed across "
              "outputs and recurse.");
      // A is at 0,0; B at 1920,0. Both distinct rects.
      final positionLines = out
          .split('\n')
          .where((l) => l.contains('position '))
          .toList();
      expect(positionLines, hasLength(2),
          reason: 'one position line per enabled output');
      expect(positionLines[0], contains('position 0,0'));
      expect(positionLines[1], contains('position 1920,0'));
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
      expect(out, contains('workspace 1 output \'"R"\''));
      expect(out, contains('workspace 2 output \'"L"\''));
      expect(out, contains('workspace 3 output \'"R"\''));
      expect(out, contains('workspace 4 output \'"L"\''));
    });

    test('workspace assignment is one exec per binding, with nothing a '
        'shell can act on', () {
      // This was one `exec swaymsg "…"` holding all nine bindings joined by
      // `; `, plus a focus-and-move pass. It never ran. kanshi hands exec
      // lines to /bin/sh after re-escaping only whitespace and the two
      // quotes (kanshi 1.9 config.c:270-276), so each `;` separated SHELL
      // commands: workspace 1 was bound and the other eight were looked up
      // as programs. See kanshi_exec_test.dart, which runs the real output
      // through the real algorithm rather than asserting on its shape.
      //
      // The race the chain existed to avoid does not apply to what is left:
      // nine independent bindings have no order to preserve.
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
      final swayMsgLines =
          out.split('\n').where((l) => l.contains('exec swaymsg')).toList();
      expect(swayMsgLines, hasLength(9),
          reason: 'one line per workspace, so none can be eaten by a '
              'separator the shell claims first');
      for (final line in swayMsgLines) {
        expect(line, isNot(contains(';')));
        expect(line, isNot(contains('&')));
        expect(line, isNot(contains('|')));
        expect(line, isNot(contains(r'$')));
      }
      // The focus-and-move half is deliberately absent: it cannot be
      // expressed without a separator, it is the visible half, and both the
      // app and the helper service perform it over IPC where no shell is
      // involved.
      expect(out, isNot(contains('move workspace to output')));
      expect(out, isNot(contains('workspace number')));
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
          .where((l) => l.contains('exec swaymsg'))
          .map((l) => l.trim().replaceFirst('exec ', ''))
          .toList();
      final ranked = resolveWorkspaceRanks([
        _mon(id: 'A', x: 0),
        _mon(id: 'B', x: 1920),
      ]);
      // The writer embeds exactly what the domain layer produces — no
      // second rendering of the same idea living in the writer.
      expect(
        embedded,
        equals(buildWorkspaceConfigExecs(
            homesFromMap(resolveWorkspaceMap(ranked)))),
      );
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

    test('grouped distribution carves contiguous bands (2 outputs)', () {
      final ranked = resolveWorkspaceRanks([
        _mon(id: 'L', x: 0),
        _mon(id: 'R', x: 1920),
      ]);
      final chain = buildSwayWorkspaceChain(
        ranked,
        distribution: WorkspaceDistribution.grouped,
      )!;
      // ws 1..5 → L, ws 6..9 → R.
      for (var ws = 1; ws <= 5; ws++) {
        expect(chain, contains("workspace $ws output 'L'"));
      }
      for (var ws = 6; ws <= 9; ws++) {
        expect(chain, contains("workspace $ws output 'R'"));
      }
    });

    test('grouped distribution gives every output a band (3 outputs)', () {
      final ranked = resolveWorkspaceRanks([
        _mon(id: 'L', x: 0),
        _mon(id: 'M', x: 1920),
        _mon(id: 'R', x: 3840),
      ]);
      final chain = buildSwayWorkspaceChain(
        ranked,
        distribution: WorkspaceDistribution.grouped,
      )!;
      // ws 1..3 → L, 4..6 → M, 7..9 → R.
      for (final ws in [1, 2, 3]) {
        expect(chain, contains("workspace $ws output 'L'"));
      }
      for (final ws in [4, 5, 6]) {
        expect(chain, contains("workspace $ws output 'M'"));
      }
      for (final ws in [7, 8, 9]) {
        expect(chain, contains("workspace $ws output 'R'"));
      }
    });
  });

  group('workspaceSlotRank', () {
    test('interleaved is round-robin', () {
      const d = WorkspaceDistribution.interleaved;
      expect([for (var w = 1; w <= 6; w++) workspaceSlotRank(w, 2, d)],
          equals([0, 1, 0, 1, 0, 1]));
    });

    test('grouped is contiguous and never exceeds n-1', () {
      const d = WorkspaceDistribution.grouped;
      final ranks = [for (var w = 1; w <= 9; w++) workspaceSlotRank(w, 2, d)];
      expect(ranks, equals([0, 0, 0, 0, 0, 1, 1, 1, 1]));
      expect(ranks.every((r) => r <= 1), isTrue);
    });
  });

  group('KanshiWriteOptions.copyWith', () {
    test('overrides only the named fields', () {
      const base = KanshiWriteOptions.swayDefaults;
      final off = base.copyWith(injectSwayWorkspaceExec: false);
      expect(off.injectSwayWorkspaceExec, isFalse);
      expect(off.injectMirrorExec, base.injectMirrorExec);
      expect(off.writeCurrentProfileMarker, base.writeCurrentProfileMarker);
      final grouped =
          base.copyWith(workspaceDistribution: WorkspaceDistribution.grouped);
      expect(grouped.workspaceDistribution, WorkspaceDistribution.grouped);
      expect(grouped.injectSwayWorkspaceExec, isTrue);
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
      // MonitorTileData.width/height hold the ROTATED extent — that is what
      // both backends produce (sway_backend.dart:110, wlr_randr_backend.dart:90)
      // and what the parser produces. So a monitor that occupies 1440x2560 on
      // screen must come back occupying 1440x2560; a round trip is an identity.
      //
      // This test used to expect the dimensions to come back SWAPPED, which
      // enshrined a double transposition on the write path: with an empty
      // modes list the writer handed the rotated extent back as if it were a
      // physical mode, transposed it in _sanitizeMonitor, and transposed it
      // again while rendering. The consequence was that the mode of a rotated
      // output flipped on every single save, so every second save asked the
      // panel for a resolution it does not have.
      final p = Profile(
        name: 'Vert',
        monitors: [_mon(id: 'A', w: 1440, h: 2560, rotation: 90)],
      );
      final rendered = KanshiConfigWriter.render([p]);

      // The config carries the PHYSICAL mode; `transform` does the rotating.
      expect(rendered, contains('mode 2560x1440@60Hz'));
      expect(rendered, contains('transform 90'));

      final m = KanshiConfigParser.parse(rendered).single.monitors.single;
      expect(m.rotation, equals(90));
      expect(m.width, equals(1440));
      expect(m.height, equals(2560));
    });

    test('a rotated monitor keeps its mode across repeated saves', () {
      final p = Profile(
        name: 'Vert',
        monitors: [_mon(id: 'A', w: 1440, h: 2560, rotation: 270)],
      );
      var rendered = KanshiConfigWriter.render([p]);
      for (var i = 0; i < 3; i++) {
        rendered =
            KanshiConfigWriter.render(KanshiConfigParser.parse(rendered));
        expect(rendered, contains('mode 2560x1440@60Hz'),
            reason: 'save #${i + 2} changed the mode');
      }
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
      //   2) a direct `exec wl-mirror` so kanshi spawns the mirror at
      //      session start when the GUI isn't running yet.
      // The pgrep guard this used to carry was a shell pipeline, and kanshi
      // leaves `|` and `||` bare for /bin/sh — so the guard never ran and
      // neither did wl-mirror. Duplicates are handled by MirrorRunner, which
      // can actually see them.
      expect(rendered, contains("# kanshi_gui:mirror 'B'='A'"),
          reason: 'Mirror state is persisted as an annotation.');
      expect(rendered, contains('exec wl-mirror'),
          reason: 'kanshi has to be able to start the mirror without the '
              'made the boot-time spawn a no-op in 1.5.10).');
      expect(rendered, contains('--fullscreen-output "B" "A"'),
          reason: 'Literal substring + trailing space pins the destination, '
              'avoiding both regex metachars and prefix collisions.');
      expect(
          rendered,
          contains(
              'wl-mirror --scaling fit --fullscreen-output "B" "A"'),
          reason: 'Guarded fallback spawns the mirror with explicit '
              '`--scaling fit` so cropping cannot regress to cover-mode.');
      expect(rendered, isNot(contains('pgrep')),
          reason: 'No shell pipeline: kanshi leaves | and || bare for sh, so '
              'a guard written that way never runs and neither does the '
              'command it was guarding.');

      final reparsed =
          KanshiConfigParser.parse(rendered).single.monitors;
      final a = reparsed.firstWhere((m) => m.id == 'A');
      final b = reparsed.firstWhere((m) => m.id == 'B');
      expect(a.mirrorOf, isNull,
          reason: 'Source tile is unaffected by the annotation.');
      expect(b.mirrorOf, equals('A'),
          reason: 'Destination tile must recover its mirror target.');
    });

    test('one mirror exec per destination, and no more', () {
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
      expect(execLines[0], contains('--fullscreen-output "B"'));
      expect(execLines[1], contains('--fullscreen-output "C"'));
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

  group('overlap guard & round-trip', () {
    test('an overlapping profile is repacked to non-overlapping positions',
        () {
      final profiles = [
        Profile(name: 'Bad', monitors: [
          _mon(id: 'A', x: 0),
          _mon(id: 'B', x: 0), // stacked exactly on top of A
        ]),
      ];
      final out = KanshiConfigWriter.render(profiles);
      expect(
        out,
        contains("output 'A' enable scale 1.00 mode 1920x1080@60Hz "
            "transform normal position 0,0"),
      );
      expect(
        out,
        contains("output 'B' enable scale 1.00 mode 1920x1080@60Hz "
            "transform normal position 1920,0"),
        reason: 'B must be repacked flush to the right of A, never stacked.',
      );
      // And the written config genuinely round-trips to a clean layout.
      final parsed = KanshiConfigParser.parse(out).single.monitors;
      expect(LayoutMath.findOverlaps(parsed), isEmpty);
    });

    test('render → parse → render is stable (no layout drift)', () {
      final profiles = [
        Profile(name: 'Desk', monitors: [
          _mon(id: 'A', x: 0),
          _mon(id: 'B', x: 1920),
          _mon(id: 'C', x: 3840, w: 2560),
        ]),
      ];
      final out1 = KanshiConfigWriter.render(profiles);
      final out2 = KanshiConfigWriter.render(KanshiConfigParser.parse(out1));
      expect(out2, equals(out1),
          reason: 'A clean layout must survive a parse/render cycle '
              'byte-for-byte — drift here is exactly what made screens '
              'jump and overlap on reload.');
    });
  });
}
