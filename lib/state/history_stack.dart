import 'package:kanshi_gui/models/monitor_tile_data.dart';
import 'package:kanshi_gui/models/profiles.dart';

/// One undoable point in time: every profile, plus which one was active.
class HistoryEntry {
  final List<Profile> profiles;
  final int? activeIndex;

  /// What the user did, phrased for a toast: "Undone: move DP-1".
  final String label;

  const HistoryEntry({
    required this.profiles,
    required this.activeIndex,
    required this.label,
  });
}

/// Undo/redo over whole-profile snapshots.
///
/// Snapshots rather than inverse operations: an operation-based history would
/// need an exact inverse for every mutation, including the ones that reach
/// the compositor and can fail there. Whole-profile copies are cheap at this
/// size (a handful of profiles with a handful of monitors) and cannot go
/// subtly wrong.
///
/// Every copy is deep at the list level — `[...p.monitors]` — because Profile
/// is mutable and handing out the same list would let a later edit rewrite
/// history in place. MonitorTileData itself is immutable, so copying the list
/// is enough.
class HistoryStack {
  /// Kept bounded: a drag can push an entry per commit and the snapshots hold
  /// every profile.
  final int cap;

  HistoryStack({this.cap = 30});

  final List<HistoryEntry> _undo = [];
  final List<HistoryEntry> _redo = [];

  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;

  String? get nextUndoLabel => _undo.isEmpty ? null : _undo.last.label;
  String? get nextRedoLabel => _redo.isEmpty ? null : _redo.last.label;

  /// Records the state *before* a mutation.
  ///
  /// [overrides] replaces individual monitors of the active profile by id.
  /// A drag has already written mid-drag positions into the profile by the
  /// time it commits, so the honest "before" is the pre-drag tile, not what
  /// is currently in the model — otherwise undo returns the user to the last
  /// mid-drag frame instead of where they started.
  void push(
    List<Profile> profiles,
    int? activeIndex,
    String label, {
    Map<String, MonitorTileData>? overrides,
  }) {
    final snap = <Profile>[];
    for (var i = 0; i < profiles.length; i++) {
      final p = profiles[i];
      final mons = [...p.monitors];
      if (i == activeIndex && overrides != null) {
        for (var j = 0; j < mons.length; j++) {
          final ov = overrides[mons[j].id];
          if (ov != null) mons[j] = ov;
        }
      }
      snap.add(Profile(
        name: p.name,
        monitors: mons,
        workspaceMap:
            p.workspaceMap == null ? null : Map.of(p.workspaceMap!),
      ));
    }
    _push(_undo, HistoryEntry(
      profiles: snap,
      activeIndex: activeIndex,
      label: label,
    ));
    // A fresh mutation makes the redo branch unreachable.
    _redo.clear();
  }

  /// Pops the newest undo entry, recording [current] for redo. Null when
  /// there is nothing to undo.
  HistoryEntry? undo(HistoryEntry current) {
    if (_undo.isEmpty) return null;
    final entry = _undo.removeLast();
    _push(_redo, HistoryEntry(
      profiles: current.profiles,
      activeIndex: current.activeIndex,
      // Redo is labelled with the step it replays, not the state it came
      // from, so "Undone: move DP-1" is followed by "Redone: move DP-1".
      label: entry.label,
    ));
    return entry;
  }

  /// Pops the newest redo entry, recording [current] for undo.
  HistoryEntry? redo(HistoryEntry current) {
    if (_redo.isEmpty) return null;
    final entry = _redo.removeLast();
    _push(_undo, HistoryEntry(
      profiles: current.profiles,
      activeIndex: current.activeIndex,
      label: entry.label,
    ));
    return entry;
  }

  /// Builds a snapshot of the state as it is right now.
  static HistoryEntry snapshot(
    List<Profile> profiles,
    int? activeIndex,
    String label,
  ) =>
      HistoryEntry(
        profiles: [
          for (final p in profiles)
            Profile(
              name: p.name,
              monitors: [...p.monitors],
              workspaceMap:
                  p.workspaceMap == null ? null : Map.of(p.workspaceMap!),
            ),
        ],
        activeIndex: activeIndex,
        label: label,
      );

  void clear() {
    _undo.clear();
    _redo.clear();
  }

  void _push(List<HistoryEntry> stack, HistoryEntry entry) {
    stack.add(entry);
    while (stack.length > cap) {
      stack.removeAt(0);
    }
  }
}
