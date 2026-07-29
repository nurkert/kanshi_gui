import 'dart:ui' show Rect;

import 'package:kanshi_gui/models/monitor_tile_data.dart';
import 'package:kanshi_gui/services/layout_math.dart';

/// Per-drag bookkeeping for the alignment-escape heuristic.
///
/// The alignment magnet is helpful right up until the user is deliberately
/// trying to place a screen slightly off-centre, at which point it fights
/// them. Counting escapes per axis lets it back off once the user has
/// clearly said no twice, and re-arm on the next grab.
class DragSession {
  bool lastYAlignmentApplied = false;
  bool lastXAlignmentApplied = false;
  int yEscapeCount = 0;
  int xEscapeCount = 0;

  /// The tile as it was when the grab started. `updateMonitor` writes
  /// mid-drag positions straight into the profile, so a cancellation needs
  /// this to put back what the user actually had.
  MonitorTileData? rollbackOrigin;
}

/// Everything that is true only while a pointer is down.
///
/// Kept apart from the controller because it has a different lifetime from
/// all the other state: it is created on mouse-down, mutated tens of times a
/// second, and must be torn down by events that have nothing to do with
/// dragging — a hotplug or a profile switch invalidates a gesture in flight,
/// because the layout it started in no longer exists.
class DragSessions {
  /// How often the user may pull out of an alignment snap before that axis's
  /// magnet gives up for the rest of the grab.
  static const int alignmentEscapeLimit = 2;

  /// Scale values the slider rasters onto on release. Chosen for real-world
  /// HiDPI scenarios; deliberately excludes integer scales above 3, which
  /// are essentially never useful and would create an "I can't get off 1.0"
  /// trap if every integer were a magnet.
  static const List<double> scaleSnapValues = [
    1.0, 1.25, 1.333, 1.5, 1.75, 2.0, 2.5, 3.0,
  ];
  static const double scaleSnapTolerance = 0.03;

  final Map<String, DragSession> _sessions = {};
  final Map<String, double> _lastSnappedScale = {};

  int _cancelEpoch = 0;
  Rect? _pinnedBounds;
  List<SnapLine> _activeLines = const [];

  /// Called when something worth a repaint changed.
  void Function()? onChanged;

  /// Bumped whenever a gesture is invalidated from outside. Tiles snapshot it
  /// on [begin] and compare on every update; a mismatch means the drag they
  /// are in the middle of no longer refers to a layout that exists.
  int get cancelEpoch => _cancelEpoch;

  /// The canvas fit is frozen to this while dragging, so the layout does not
  /// rescale under the cursor as the tile moves.
  Rect? get pinnedBounds => _pinnedBounds;

  List<SnapLine> get activeSnapLines => List.unmodifiable(_activeLines);

  bool get isDragging => _sessions.isNotEmpty;

  /// Starts a session for [id]. [cluster] is the independently-positioned
  /// part of the layout — enabled, non-mirrored — because pinning a bounding
  /// box that included parked tiles would freeze the canvas around positions
  /// the user cannot see.
  int begin(
    String id,
    MonitorTileData? rollback,
    List<MonitorTileData> cluster,
  ) {
    _sessions[id] = DragSession()..rollbackOrigin = rollback;
    if (cluster.isNotEmpty) {
      _pinnedBounds = LayoutMath.boundingBox(cluster);
      onChanged?.call();
    }
    return _cancelEpoch;
  }

  /// Ends a session normally (pointer up), releasing the canvas pin.
  void end(String id) {
    _sessions.remove(id);
    if (_pinnedBounds != null) {
      _pinnedBounds = null;
      onChanged?.call();
    }
  }

  /// Invalidates every session. Returns the per-output states the caller must
  /// write back, so the profile ends up where it was before the drag rather
  /// than at whatever mid-drag frame happened to be last.
  ///
  /// Returns an empty map when there was nothing in flight.
  Map<String, MonitorTileData> cancelAll() {
    if (_sessions.isEmpty && _pinnedBounds == null) return const {};
    final rollbacks = <String, MonitorTileData>{};
    for (final entry in _sessions.entries) {
      final origin = entry.value.rollbackOrigin;
      if (origin != null) rollbacks[entry.key] = origin;
    }
    _sessions.clear();
    _pinnedBounds = null;
    _cancelEpoch++;
    return rollbacks;
  }

  /// Computes snapping for [dragged] against [cluster] without mutating the
  /// layout, and publishes the guide lines.
  ///
  /// Also tracks alignment escapes: a *transition* from "alignment was
  /// applied" to "no longer applied, while the corresponding edge is still
  /// snapped" is the user pulling out of the magnet on purpose.
  SnapResult previewSnap(
    MonitorTileData dragged,
    List<MonitorTileData> cluster,
    double threshold,
  ) {
    final session = _sessions[dragged.id];
    final result = LayoutMath.snapToEdges(
      dragged,
      cluster,
      threshold,
      yAlignmentEnabled:
          (session?.yEscapeCount ?? 0) < alignmentEscapeLimit,
      xAlignmentEnabled:
          (session?.xEscapeCount ?? 0) < alignmentEscapeLimit,
    );

    if (session != null) {
      if (session.lastYAlignmentApplied &&
          !result.yAlignmentApplied &&
          result.xEdgeSnapped) {
        session.yEscapeCount++;
      }
      if (session.lastXAlignmentApplied &&
          !result.xAlignmentApplied &&
          result.yEdgeSnapped) {
        session.xEscapeCount++;
      }
      session.lastYAlignmentApplied = result.yAlignmentApplied;
      session.lastXAlignmentApplied = result.xAlignmentApplied;
    }

    if (!_sameLines(_activeLines, result.activeLines)) {
      _activeLines = result.activeLines;
      onChanged?.call();
    }
    return result;
  }

  /// Snaps [dragged] for the final commit, honouring the escape counters the
  /// preview accumulated during this grab. Does not publish guide lines —
  /// the drag is over.
  SnapResult commitSnap(
    MonitorTileData dragged,
    List<MonitorTileData> cluster,
    double threshold,
  ) {
    final session = _sessions[dragged.id];
    return LayoutMath.snapToEdges(
      dragged,
      cluster,
      threshold,
      yAlignmentEnabled:
          (session?.yEscapeCount ?? 0) < alignmentEscapeLimit,
      xAlignmentEnabled:
          (session?.xEscapeCount ?? 0) < alignmentEscapeLimit,
    );
  }

  void clearPreview() {
    if (_activeLines.isNotEmpty) {
      _activeLines = const [];
      onChanged?.call();
    }
  }

  /// Rasters [raw] onto a common HiDPI scale when it is close enough.
  ///
  /// Direction-aware: having just left a value, the slider has to travel
  /// roughly twice the tolerance before that same value will grab again.
  /// Without it, dragging away from 1.0 snaps straight back and the scale
  /// appears stuck.
  double snapScale(String id, double raw, {required bool enabled}) {
    if (!enabled) {
      _lastSnappedScale.remove(id);
      return raw;
    }
    final last = _lastSnappedScale[id];
    double? best;
    var bestDist = double.infinity;
    for (final v in scaleSnapValues) {
      final dist = (raw - v).abs();
      if (dist > scaleSnapTolerance) continue;
      if (last != null && (last - v).abs() < 1e-9) {
        if (dist > 0 && (raw - last).abs() < scaleSnapTolerance * 2) {
          continue;
        }
      }
      if (dist < bestDist) {
        bestDist = dist;
        best = v;
      }
    }
    if (best != null) {
      _lastSnappedScale[id] = best;
      return best;
    }
    _lastSnappedScale.remove(id);
    return raw;
  }

  static bool _sameLines(List<SnapLine> a, List<SnapLine> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
