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
/// comparison) doesn't have to re-derive it.
///
/// Returns `null` when [ranked] is empty — there's no workspace
/// distribution to express.
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
String? buildSwayWorkspaceChain(
  List<WorkspaceRankEntry> ranked, {
  int maxWorkspaces = 9,
  WorkspaceDistribution distribution = WorkspaceDistribution.interleaved,
  Map<String, OutputCriteria> criteria = const {},
}) {
  final n = ranked.length;
  if (n == 0) return null;
  final parts = <String>[];
  for (var ws = 1; ws <= maxWorkspaces; ws++) {
    final rank = workspaceSlotRank(ws, n, distribution,
        maxWorkspaces: maxWorkspaces);
    // Phase 1: persistent output binding. NO `number` keyword — see
    // the docstring above for why.
    parts.add('workspace $ws output ${_execCriteria(ranked[rank].id, criteria)}');
  }
  for (var ws = 1; ws <= maxWorkspaces; ws++) {
    final rank = workspaceSlotRank(ws, n, distribution,
        maxWorkspaces: maxWorkspaces);
    // Phase 2: focus the numeric slot (renamed-workspace safe) and
    // force-move any pre-existing workspace to its new home output.
    parts.add('workspace number $ws');
    parts.add(
        'move workspace to output ${_execCriteria(ranked[rank].id, criteria)}');
  }
  parts.add('workspace number 1');
  return parts.join('; ');
}

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
