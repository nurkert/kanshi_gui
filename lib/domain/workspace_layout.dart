// Pure Dart. No Flutter, no dart:io.

import 'package:kanshi_gui/domain/output_identity.dart';
import 'package:kanshi_gui/models/monitor_tile_data.dart';

/// How the numeric workspaces 1..N are spread across the ranked outputs
/// when [KanshiWriteOptions.injectSwayWorkspaceExec] is on. See
/// [workspaceSlotRank] for the exact assignment each mode produces.
enum WorkspaceDistribution {
  /// Round-robin by left-to-right position: ws `w` → rank `(w-1) mod N`.
  /// Two screens give the left one 1/3/5/7/9 and the right one 2/4/6/8.
  interleaved,

  /// Contiguous blocks: the workspace range is split into N near-equal
  /// runs, so each monitor owns a consecutive band. Two screens give the
  /// left one 1..5 and the right one 6..9.
  grouped,
}

/// The complete `workspace number → output id` assignment for workspaces
/// 1..[maxWorkspaces], across the ranked outputs.
///
/// This is the one place that decides where a workspace lives, and it always
/// answers for **every** workspace in the range. That totality is the whole
/// point:
///
/// M9 let a setup carry its own observed map and used it *instead of* the
/// rule. But sway only reports workspaces that currently exist — it does not
/// pre-create empty ones — so an observation is always a partial snapshot.
/// A three-screen desk with workspaces 1, 2, 3 open learned exactly those
/// three, and 4..9 were then left with no `workspace N output X` binding at
/// all. Sway creates an unbound workspace on whatever output has focus, which
/// is the long-standing "$mod+9 opens wherever my cursor is" complaint — and
/// worse, the next observation recorded that accident as a preference and
/// pinned it.
///
/// So [learned] is an *overlay* on the rule, never a replacement. Entries
/// outside 1..[maxWorkspaces], or naming an output this setup does not have,
/// are dropped rather than emitted: a binding sway cannot resolve is silently
/// ignored, which puts the workspace back in the homeless state this function
/// exists to prevent.
Map<int, String> resolveWorkspaceMap(
  List<WorkspaceRankEntry> ranked, {
  int maxWorkspaces = 9,
  WorkspaceDistribution distribution = WorkspaceDistribution.interleaved,
  Map<int, String>? learned,
}) {
  final n = ranked.length;
  if (n == 0) return const {};
  final map = <int, String>{
    for (var ws = 1; ws <= maxWorkspaces; ws++)
      ws: ranked[workspaceSlotRank(ws, n, distribution,
              maxWorkspaces: maxWorkspaces)]
          .id,
  };
  if (learned == null) return map;
  final known = {for (final e in ranked) e.id};
  for (final entry in learned.entries) {
    if (entry.key < 1 || entry.key > maxWorkspaces) continue;
    if (!known.contains(entry.value)) continue;
    map[entry.key] = entry.value;
  }
  return map;
}

/// Builds the semicolon-joined `swaymsg` command that distributes the
/// numeric workspaces 1..[maxWorkspaces] across the ranked outputs.
///
/// Workspaces are distributed **interleaved** by left-to-right
/// position. With N ranked outputs (0..N-1 left-to-right), workspace
/// `w` (1-indexed) lands on the rank `(w - 1) mod N`. Two screens give
/// the left one workspaces 1/3/5/7/9 and the right one 2/4/6/8;
/// three screens give 1/4/7, 2/5/8, 3/6/9 — the number-keys 1..9
/// walk left-to-right across the displays, looping back as you press
/// higher numbers.
///
/// Caller supplies a pre-computed ranked list (typically via
/// [resolveWorkspaceRanks]) so the controller-side verify-and-fix path
/// (which also wants to know the desired ws→output mapping for
/// comparison) doesn't have to re-derive it. [learned] overlays an observed
/// map onto the rule; see [resolveWorkspaceMap].
///
/// Returns `null` when [ranked] is empty — there's no workspace
/// distribution to express.
String? buildSwayWorkspaceChain(
  List<WorkspaceRankEntry> ranked, {
  int maxWorkspaces = 9,
  WorkspaceDistribution distribution = WorkspaceDistribution.interleaved,
  Map<int, String>? learned,
  Map<String, OutputCriteria> criteria = const {},
}) {
  return buildWorkspaceChain(
    resolveWorkspaceMap(
      ranked,
      maxWorkspaces: maxWorkspaces,
      distribution: distribution,
      learned: learned,
    ),
    criteria: criteria,
  );
}

/// Renders a `workspace number → output id` [map] as the chained swaymsg
/// command that puts every one of those workspaces on its output.
///
/// Why a single chained invocation instead of N separate `exec swaymsg`
/// lines:
///
///  1. Race elimination — kanshi spawns each `exec` in its own
///     fork/exec. Multiple parallel invocations land in sway
///     out-of-order; workspace 5 could be processed before workspace 2
///     and leak windows onto the wrong output. A single compound
///     command is processed in declared order by sway's IPC.
///
///  2. Sway's `workspace N output X` is *passive* — it only specifies
///     where workspace N is created at runtime; it does NOT move
///     existing workspaces. To relocate workspaces that already exist
///     with windows (e.g. ws 1 opened before docking), we focus each
///     in turn and run `move workspace to output X`. This forces the
///     move for existing workspaces and is a no-op for empty ones.
///
/// The chain first declares every output target up front (so the later
/// `workspace N` focus picks the right home AND so any *future*
/// workspace creation during the session lands on the assigned
/// monitor without help from kanshi_gui), then walks the workspaces
/// and moves each one into place, and ends on `workspace number 1`
/// so focus lands on the leftmost-rank monitor — typically the
/// user's primary attention area after docking, and stable across
/// runs.
///
/// Phase-1 (the output binding) deliberately uses `workspace N output X`
/// rather than `workspace number N output X`. Sway stores the binding
/// in its `workspace_outputs` list keyed by workspace name; the
/// `number` variant produces a `success:true` IPC reply but the stored
/// key does not match what sway looks up when a workspace is later
/// created with `workspace number N`, so the binding never takes
/// effect on workspace destruction + recreation. Without the binding,
/// a $mod+5 from a different output creates ws 5 on the focused
/// output instead of its assigned home — the long-standing complaint
/// that workspaces above 3 (or above N for N monitors) "open wherever
/// the cursor is". This binding persists for the whole sway session.
///
/// Phase-2 keeps `workspace number N` for the focus + force-move
/// because the rename concern (`1: code`) is real: a user who renamed
/// their numeric workspaces needs the numeric-slot selector here,
/// otherwise the unsuffixed form would create an empty "1" alongside
/// the live "1: code" and silently fragment their setup.
String? buildWorkspaceChain(
  Map<int, String> map, {
  Map<String, OutputCriteria> criteria = const {},
  int? returnFocusTo,
  Map<int, List<OutputCriteria>>? homes,
}) {
  if (map.isEmpty) return null;
  if (!_allTargetsSafe(map, criteria)) return null;
  // The declaration half states every screen the workspace could belong to,
  // because it is the half that outlives this desk; the move half names the
  // one screen that is plugged in right now, because moving somewhere that
  // is not there is not a thing sway can do.
  final declarations =
      buildWorkspaceDeclarations(homes ?? homesFromMap(map, criteria: criteria));
  if (declarations == null) return null;
  final numbers = map.keys.toList()..sort();
  final parts = <String>[declarations];
  for (final ws in numbers) {
    // Phase 2: focus the numeric slot (renamed-workspace safe) and
    // force-move any pre-existing workspace to its new home output.
    parts.add('workspace number $ws');
    parts.add('move workspace to output ${_execCriteria(map[ws]!, criteria)}');
  }
  // Where the walk leaves the user. It used to be workspace 1, always —
  // "the leftmost screen, a predictable landing". Predictable is not the same
  // as wanted: run from a background service while someone is working on
  // workspace 6, it takes them to 1 for no reason they can see. Pass
  // [returnFocusTo] and the chain hands them back.
  parts.add('workspace number ${returnFocusTo ?? numbers.first}');
  return parts.join('; ');
}

/// Phase 1 on its own: the `workspace N output X …` bindings, with no focus
/// dance and no moves.
///
/// This half is invisible — it tells sway where each workspace belongs and
/// touches nothing that exists — which makes it safe to run on every launch.
/// That matters because a missing binding is precisely what the repair pass
/// cannot detect: sway reports the workspaces it HAS, so a workspace with no
/// home and no existence looks identical to one that is simply closed.
///
/// Each workspace gets its whole preference list, not one screen, and that is
/// the fix for the bug that made this feature look broken on every docked
/// laptop. See [buildWorkspaceConfigExecs] for the measurements.
String? buildWorkspaceDeclarations(Map<int, List<OutputCriteria>> homes) {
  // Straight to sway's IPC socket, where no shell is involved and sway's own
  // parser strips one layer of quoting. See [OutputCriteria.swayExecForm].
  final lines = _declarationLines(homes, (c) => c.swayExecForm);
  if (lines.isEmpty) return null;
  return lines.join('; ');
}

/// The `workspace N output X …` bindings as ONE COMMAND PER LINE, for the
/// kanshi config.
///
/// Not a chain, and that is the whole point. kanshi hands each `exec` line to
/// `/bin/sh` after re-escaping only whitespace and quotes, so a `;` between
/// commands is a shell separator: the first command ran, and every one after
/// it was looked up as a program and reported `not found`. Nine bindings
/// joined into one line meant eight of them never happened — which is exactly
/// the "$mod+9 opens under the cursor" this feature exists to fix.
///
/// One command per line has no separator to be eaten, and the order of
/// independent bindings does not matter, so kanshi's warning that exec
/// commands "may not be preserved" in order costs nothing here.
///
/// Returns an empty list when a workspace has no safely expressible target;
/// see [isShellSafeCriteria] and [_declarationLines].
List<String> buildWorkspaceConfigExecs(Map<int, List<OutputCriteria>> homes) =>
    [
      // scfg, then kanshi's re-escaping, then /bin/sh, then sway: three layers
      // strip one quote each. See [OutputCriteria.kanshiExecForm].
      for (final line in _declarationLines(homes, (c) => c.kanshiExecForm))
        'swaymsg $line',
    ];

/// One `workspace N output A B C` per workspace, shared by the config writer
/// and the IPC path so the two cannot spell a binding differently.
///
/// Several outputs per workspace, and the reason is the whole bug:
///
/// sway's `cmd_workspace` APPENDS to a workspace's output list and never
/// clears it, and `workspace_get_initial_output` walks that list and takes
/// the first entry that resolves to a connected screen. Measured against
/// sway 1.12: declare `workspace 5 output A`, then `workspace 5 output B`,
/// then create workspace 5 — it is born on **A**. The first declaration in a
/// sway session wins for the rest of that session.
///
/// A laptop is therefore broken by design under one-target declarations. Boot
/// undocked and kanshi activates the laptop-only setup, which binds all nine
/// workspaces to the built-in panel. Dock, kanshi switches setups and binds
/// them to the external screens — appended behind the panel, which is still
/// connected, so it still wins. Every workspace opened from then on is born
/// on the laptop screen, forever, whatever the config says. Nothing in the
/// file is wrong; sway simply never looks at it again.
///
/// The only reset sway offers is `swaymsg reload`, and that is not usable:
/// measured on the same build, it also throws away every output position and
/// scale the compositor was given over IPC and re-arranges the desk from
/// scratch. Curing a workspace binding by scrambling the monitors is not a
/// cure.
///
/// So the binding is stated as a *preference list* instead — every screen
/// this workspace could belong to across all remembered setups, most specific
/// desk first. sway takes the first one that is plugged in. Because the list
/// does not depend on what is connected, every re-declaration appends an
/// identical copy, and an identical copy cannot shadow anything: stacking
/// becomes a no-op instead of a trap. Verified against sway 1.12 —
/// `workspace 15 output <absent> <present>` declared while the first screen
/// was unplugged still puts workspace 15 on it once it appears.
///
/// A workspace whose list contains anything a shell cannot be trusted with is
/// dropped whole rather than partially: emitting only the safe half would
/// silently promote a fallback to first choice, and a workspace on the wrong
/// screen is a worse answer than a workspace the rule stays quiet about.
List<String> _declarationLines(
  Map<int, List<OutputCriteria>> homes,
  String Function(OutputCriteria) render,
) {
  if (homes.isEmpty) return const [];
  final numbers = homes.keys.toList()..sort();
  final lines = <String>[];
  for (final ws in numbers) {
    final targets = homes[ws]!;
    if (targets.isEmpty) continue;
    if (!targets.every((c) => c.isShellSafe)) continue;
    // NO `number` keyword — see [buildWorkspaceChain] for why.
    lines.add('workspace $ws output ${targets.map(render).join(' ')}');
  }
  return lines;
}

/// Lifts a single-target `workspace → output id` map into the preference-list
/// shape, for callers that genuinely mean exactly one screen.
Map<int, List<OutputCriteria>> homesFromMap(
  Map<int, String> map, {
  Map<String, OutputCriteria> criteria = const {},
}) =>
    {
      for (final e in map.entries)
        e.key: [criteria[e.value] ?? OutputCriteria.connector(e.value)],
    };

/// Fails the whole chain closed if any target could not be safely quoted.
///
/// The chain is emitted as `exec swaymsg "…"` and kanshi hands that to a
/// shell, so a target carrying shell syntax is a command, not a name. The
/// criteria chooser already declines to use an unsafe EDID description, which
/// leaves only a connector name that somehow contains shell syntax — a config
/// edited by hand, or a compositor reporting something very strange. Emitting
/// nothing costs the user their workspace placement and nothing else; the
/// alternative costs them their session.
bool _allTargetsSafe(
  Map<int, String> map,
  Map<String, OutputCriteria> criteria,
) =>
    map.values.every((id) =>
        (criteria[id] ?? OutputCriteria.connector(id)).isShellSafe);

/// How an output is spelled inside the `exec swaymsg \"…\"` chain.
///
/// The chain is already inside a double-quoted shell string, so kanshi(5)
/// documents the nesting a description needs:
///
/// > exec swaymsg workspace 1, move workspace to output '\"Some Other Company
/// > GTBZ 2525\"'
///
/// Getting this wrong is silent: sway does not fail the command, it just
/// drops the `output` target it cannot resolve and the workspace stays
/// wherever it was created.
String _execCriteria(String id, Map<String, OutputCriteria> criteria) =>
    (criteria[id] ?? OutputCriteria.connector(id)).swayExecForm;

/// Maps a 1-indexed workspace number [ws] to the 0..N-1 output rank that
/// owns it, for [n] ranked outputs under the chosen [distribution]. Shared
/// by [buildSwayWorkspaceChain] (which builds the swaymsg command) and the
/// controller's verify-and-fix path (which computes the *expected* live
/// mapping to diff against), so the two never drift apart.
///
///  * [WorkspaceDistribution.interleaved] → `(ws-1) mod n` (round-robin).
///  * [WorkspaceDistribution.grouped] → `((ws-1) * n) ~/ maxWorkspaces`,
///    which carves 1..[maxWorkspaces] into N near-equal contiguous bands
///    (e.g. N=2 → 1..5 / 6..9; N=3 → 1..3 / 4..6 / 7..9). Every monitor
///    gets at least one slot as long as `n <= maxWorkspaces`.
int workspaceSlotRank(
  int ws,
  int n,
  WorkspaceDistribution distribution, {
  int maxWorkspaces = 9,
}) {
  switch (distribution) {
    case WorkspaceDistribution.interleaved:
      return (ws - 1) % n;
    case WorkspaceDistribution.grouped:
      final rank = ((ws - 1) * n) ~/ maxWorkspaces;
      return rank >= n ? n - 1 : rank;
  }
}

class WorkspaceRankEntry {
  final String id;
  final int rank;
  final bool explicit;
  const WorkspaceRankEntry(this.id, this.rank, this.explicit);
}

/// Resolves each enabled monitor to a unique 0..N-1 rank used for the
/// interleaved workspace distribution. Explicit `workspaceRank` overrides
/// win first (in X-ascending order on collision); remaining slots are
/// filled by the still-unranked monitors in X-ascending order.
///
/// Returned list is ordered **by effective rank** — element at index `i`
/// owns workspace `i+1`, `i+1+N`, `i+1+2N`, …
List<WorkspaceRankEntry> resolveWorkspaceRanks(List<MonitorTileData> mons) {
  if (mons.isEmpty) return const [];
  final n = mons.length;
  final byX = mons.toList()
    ..sort((a, b) {
      final byXCmp = a.x.compareTo(b.x);
      if (byXCmp != 0) return byXCmp;
      return a.id.compareTo(b.id);
    });

  final byRank = <int, MonitorTileData>{};
  final explicit = <String>{};
  // Pass 1: claim explicit ranks in X-order so collisions are resolved
  // deterministically (leftmost wins).
  final unranked = <MonitorTileData>[];
  for (final m in byX) {
    final r = m.workspaceRank;
    if (r == null) {
      unranked.add(m);
      continue;
    }
    final clamped = r < 0 ? 0 : (r >= n ? n - 1 : r);
    if (byRank.containsKey(clamped)) {
      unranked.add(m);
      continue;
    }
    byRank[clamped] = m;
    explicit.add(m.id);
  }
  // Pass 2: fill the remaining ranks with the still-unranked monitors,
  // taking the lowest free rank for the leftmost monitor.
  var nextRank = 0;
  for (final m in unranked) {
    while (byRank.containsKey(nextRank)) {
      nextRank++;
    }
    byRank[nextRank] = m;
    nextRank++;
  }
  return [
    for (var i = 0; i < n; i++)
      WorkspaceRankEntry(byRank[i]!.id, i, explicit.contains(byRank[i]!.id)),
  ];
}
