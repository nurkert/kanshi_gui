import 'package:flutter/foundation.dart';
import 'package:kanshi_gui/domain/output_identity.dart';
import 'package:kanshi_gui/domain/workspace_layout.dart';
import 'package:kanshi_gui/models/monitor_tile_data.dart';
import 'package:kanshi_gui/services/monitor_service.dart';

/// Keeps the sway workspaces on the screens the active setup says they belong
/// on.
///
/// The placement itself is kanshi's job: the writer emits an
/// `exec swaymsg "…"` chain into every profile, and kanshi re-runs it on each
/// profile activation. `kanshi(5)` is explicit that exec commands "are
/// executed asynchronously and their order may not be preserved", so on a
/// cold boot that chain races sway's output discovery. An output sway does
/// not know by name yet has its `output 'X'` target silently dropped, and the
/// workspaces land in creation order.
///
/// This class is the repair pass for that race: read the live mapping, diff it
/// against what the active setup implies, and re-run the chain only when they
/// disagree. Idempotent and best-effort — it is a nicety on top of the real
/// mechanism, not the mechanism itself.
class WorkspacePlacement {
  final MonitorService monitors;

  /// Highest numeric workspace the chain manages.
  static const int maxWorkspaces = 9;

  WorkspacePlacement(this.monitors);

  /// Runs the repair pass.
  ///
  /// [force] skips the live-state comparison. Callers that just mutated the
  /// active profile want it, because `kanshictl reload` does not re-fire the
  /// exec line for a profile that is already active — sway would keep the old
  /// bindings while the model has the new ones.
  ///
  /// [enabled] is the user's opt-in AND the backend's capability: when
  /// workspace management is off we must not touch the live layout at all.
  Future<void> verifyAndFix({
    required bool enabled,
    required List<MonitorTileData> profileMonitors,
    required List<MonitorTileData> liveOutputs,
    required WorkspaceDistribution distribution,
    required String Function(String) resolveConnector,
    Map<int, String>? learnedMap,
    bool force = false,
    bool Function()? isCancelled,
  }) async {
    if (!enabled) return;
    if (!monitors.isLive) return;

    try {
      // Same predicate the writer uses when rendering the exec line, so the
      // two cannot disagree about which outputs are in play.
      final desired = profileMonitors
          .where((m) => m.enabled && m.mirrorOf == null)
          .toList();
      if (desired.isEmpty) return;

      // A profile entry may be keyed by EDID description rather than by the
      // port sway currently uses. Resolve, and skip anything not connected —
      // it would only produce sway warnings.
      final connected = liveOutputs.map((m) => m.id).toSet();
      final resolved = <MonitorTileData>[];
      for (final m in desired) {
        final live = resolveConnector(m.id);
        if (!connected.contains(live)) continue;
        resolved.add(m.copyWith(id: live));
      }
      if (resolved.isEmpty) return;

      final ranked = resolveWorkspaceRanks(resolved);
      if (ranked.isEmpty) return;

      // An observed map is the truth for this setup; the distribution rule
      // only fills in for one that has never been observed.
      final want = learnedMap != null && learnedMap.isNotEmpty
          ? learnedMap
          : expectedMapping(ranked, distribution);

      Map<int, String> actual;
      try {
        actual = await monitors.getWorkspaceOutputs();
      } catch (e) {
        debugPrint('workspace placement: getWorkspaceOutputs failed: $e');
        return;
      }
      if (isCancelled?.call() ?? false) return;

      if (!force && !needsRepair(want, actual)) return;

      final criteria = <String, OutputCriteria>{
        for (final m in resolved)
          if (m.edidDescriptor.isNotEmpty)
            m.id: OutputCriteria.description(m.edidDescriptor),
      };
      final chain = learnedMap != null && learnedMap.isNotEmpty
          ? buildLearnedWorkspaceChain(learnedMap, criteria: criteria)
          : buildSwayWorkspaceChain(
              ranked,
              distribution: distribution,
              criteria: criteria,
            );
      if (chain == null) return;
      try {
        await monitors.applyWorkspaceChain(chain);
      } catch (e) {
        debugPrint('workspace placement: applyWorkspaceChain failed: $e');
      }
    } catch (e, st) {
      debugPrint('workspace placement failed: $e\n$st');
    }
  }

  /// The workspace → output mapping the chain will produce.
  static Map<int, String> expectedMapping(
    List<WorkspaceRankEntry> ranked,
    WorkspaceDistribution distribution,
  ) {
    final n = ranked.length;
    return {
      for (var ws = 1; ws <= maxWorkspaces; ws++)
        ws: ranked[workspaceSlotRank(ws, n, distribution,
                maxWorkspaces: maxWorkspaces)]
            .id,
    };
  }

  /// Whether the live mapping disagrees with the intended one.
  ///
  /// Only workspaces the compositor actually has are compared: sway does not
  /// pre-create empty ones, so an absent workspace is not a mismatch — the
  /// chain's `workspace number N output X` already declared its home and it
  /// will be honoured on first focus.
  ///
  /// An out-of-range workspace also counts. A stuck workspace 10 from an
  /// earlier session is displaced by the chain, which visits 1..N and ends
  /// focused on 1; if it was empty, sway garbage-collects it.
  static bool needsRepair(Map<int, String> want, Map<int, String> actual) {
    final mismatched = actual.entries.any((e) {
      final expected = want[e.key];
      return expected != null && expected != e.value;
    });
    final hasOrphan =
        actual.keys.any((k) => k < 1 || k > maxWorkspaces);
    return mismatched || hasOrphan;
  }
}
