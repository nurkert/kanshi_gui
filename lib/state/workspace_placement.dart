import 'package:flutter/foundation.dart';
import 'package:kanshi_gui/domain/output_identity.dart';
import 'package:kanshi_gui/domain/workspace_layout.dart';
import 'package:kanshi_gui/models/monitor_tile_data.dart';
import 'package:kanshi_gui/services/monitor_service.dart';
import 'package:kanshi_gui/services/workspace_apply_lock.dart';

/// Keeps the sway workspaces on the screens the active setup says they belong
/// on.
///
/// The declarations are kanshi's job: the writer emits one
/// `exec swaymsg workspace N output …` line per workspace into every profile,
/// and kanshi runs them on each profile activation. What that CANNOT do is
/// move a workspace that already exists — a declaration only says where one
/// will be born — and it cannot correct itself either, because sway keeps the
/// first binding it was given for a workspace and ignores every later one.
///
/// This class is the repair pass for both. It reads the live mapping, diffs it
/// against what the active setup implies, and walks the workspaces into place
/// only when they disagree. Best-effort and deliberately visible-when-it-acts.
///
/// This doc used to describe the gap as an ordering race at cold boot, on the
/// strength of `kanshi(5)` warning that exec commands "are executed
/// asynchronously and their order may not be preserved". Measured on sway
/// 1.12, that is not the failure: a `workspace N output X` naming a screen
/// sway does not have yet is simply remembered, and takes effect the moment
/// that screen appears. Re-running the exec earlier or harder would have
/// fixed nothing — which is exactly the conclusion the old wording invited.
class WorkspacePlacement {
  final MonitorService monitors;

  /// Taken around the send. The helper takes the same one, so a hotplug while
  /// this window is open cannot have both walking the workspaces at once —
  /// two interleaved walks end wherever the last one happened to land.
  /// Injectable so widget tests need no filesystem.
  final Future<bool> Function(Future<void> Function())? withApplyLock;

  /// Highest numeric workspace the chain manages.
  static const int maxWorkspaces = 9;

  WorkspacePlacement(this.monitors, {this.withApplyLock});

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
    Map<int, List<OutputCriteria>>? homes,
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

      // The rule covers all of 1..maxWorkspaces; an observed map only
      // overlays it. Anything less leaves workspaces with no home at all —
      // see [resolveWorkspaceMap]. The observation is restated in the live
      // connector names `ranked` is keyed by, because a profile addressed by
      // EDID descriptor would otherwise have every entry read as unknown.
      final want = expectedMapping(
        ranked,
        distribution,
        learned: learnedMap == null
            ? null
            : {
                for (final e in learnedMap.entries)
                  e.key: resolveConnector(e.value),
              },
      );

      Map<int, String> actual;
      try {
        actual = await monitors.getWorkspaceOutputs();
      } catch (e) {
        debugPrint('workspace placement: getWorkspaceOutputs failed: $e');
        return;
      }
      if (isCancelled?.call() ?? false) return;

      // The SAME chooser the writer uses, not a hand-rolled map. Two panels of
      // the same model with no distinguishing serial share a descriptor, and
      // sway cannot tell them apart from it — [chooseOutputCriteria] falls
      // back to connector names for exactly that case. Reimplementing the map
      // inline skipped the fallback, so both screens' workspaces resolved onto
      // whichever one sway found first. This pass now runs on every launch,
      // which would have turned a rare bug into a reliable one.
      final criteria = chooseExecCriteria(
        resolved.map((m) => m.id),
        (connector) {
          final m = resolved.firstWhere((e) => e.id == connector);
          return m.edidDescriptor.isEmpty ? null : m.edidDescriptor;
        },
      );
      // Two halves, and which one runs is the whole cost/benefit of this pass.
      //
      // The full chain focuses each workspace in turn to force-move it, which
      // is visible, so it only runs when the live layout actually disagrees.
      // The declarations alone are invisible, and they cover the case this
      // pass is otherwise blind to: sway reports the workspaces it HAS, so one
      // that has no home AND does not exist yet is indistinguishable from one
      // that is simply closed. Declaring all of them every time is what stops
      // `$mod+9` opening under the cursor. See [buildWorkspaceDeclarations]
      // for what a declaration can and cannot change.
      // The walk hands focus back where it found it. Ending on workspace 1 —
      // "a predictable landing" — is fine right after docking and rude at
      // every other moment: open the app while working on workspace 6 and it
      // took the screen away for no reason the user could see. The helper was
      // taught this in 2.1.5; the app was not, and does the same thing.
      final chain = force || needsRepair(want, actual)
          ? buildWorkspaceChain(want,
              criteria: criteria,
              returnFocusTo: await monitors.focusedWorkspace(),
              homes: homes)
          : buildWorkspaceDeclarations(
              homes ?? homesFromMap(want, criteria: criteria));
      if (chain == null) return;
      Future<void> send() async {
        try {
          await monitors.applyWorkspaceChain(chain);
        } catch (e) {
          debugPrint('workspace placement: applyWorkspaceChain failed: $e');
        }
      }

      final lock = withApplyLock ??
          (Future<void> Function() a) =>
              WorkspaceApplyLock(WorkspaceApplyLock.applyLock).guard(a);
      if (!await lock(send)) {
        debugPrint('workspace placement: the helper is mid-apply; leaving it');
      }
    } catch (e, st) {
      debugPrint('workspace placement failed: $e\n$st');
    }
  }

  /// The workspace → output mapping the chain will produce, for every
  /// workspace 1..[maxWorkspaces].
  static Map<int, String> expectedMapping(
    List<WorkspaceRankEntry> ranked,
    WorkspaceDistribution distribution, {
    Map<int, String>? learned,
  }) =>
      resolveWorkspaceMap(
        ranked,
        maxWorkspaces: maxWorkspaces,
        distribution: distribution,
        learned: learned,
      );

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
