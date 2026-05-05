import 'dart:math';
import 'dart:ui';

import 'package:kanshi_gui/models/monitor_tile_data.dart';

/// Result of [LayoutMath.computeDisplay]: contains the scaling/offset chosen
/// to fit the monitor layout into a viewport, plus the per-monitor display
/// rectangles already projected into viewport coordinates.
class DisplayLayout {
  final double scaleFactor;
  final double offsetX;
  final double offsetY;
  /// Absolute monitor-space coordinates that map to (offsetX, offsetY) in
  /// the viewport. Callers that need to project additional points (snap
  /// guide lines, drag-end coordinate translation) must use these so they
  /// stay aligned with [displayMonitors].
  final double originX;
  final double originY;
  final List<MonitorTileData> displayMonitors;

  const DisplayLayout({
    required this.scaleFactor,
    required this.offsetX,
    required this.offsetY,
    required this.originX,
    required this.originY,
    required this.displayMonitors,
  });

  static const empty = DisplayLayout(
    scaleFactor: 1.0,
    offsetX: 0.0,
    offsetY: 0.0,
    originX: 0.0,
    originY: 0.0,
    displayMonitors: <MonitorTileData>[],
  );
}

/// Which axis a snap line refers to.
enum SnapAxis { vertical, horizontal }

/// A guide line that a [LayoutMath.snapToEdges] call produced. The
/// coordinates are in the *absolute* monitor space (same coordinate system
/// as [MonitorTileData.x] / [MonitorTileData.y]); the painter is
/// responsible for projecting them into viewport coordinates via the same
/// mapping that [LayoutMath.computeDisplay] uses for the tiles.
class SnapLine {
  final double x1;
  final double y1;
  final double x2;
  final double y2;
  final SnapAxis axis;

  const SnapLine({
    required this.x1,
    required this.y1,
    required this.x2,
    required this.y2,
    required this.axis,
  });

  @override
  bool operator ==(Object other) =>
      other is SnapLine &&
      other.x1 == x1 &&
      other.y1 == y1 &&
      other.x2 == x2 &&
      other.y2 == y2 &&
      other.axis == axis;

  @override
  int get hashCode => Object.hash(x1, y1, x2, y2, axis);
}

/// Outcome of [LayoutMath.snapToEdges]: the (possibly) repositioned tile,
/// the active guide lines, and per-axis booleans telling the caller which
/// snap categories actually engaged. The latter let stateful callers (the
/// drag-session tracker in `KanshiController`) detect "user just escaped
/// alignment" transitions without re-running the math.
class SnapResult {
  final MonitorTileData tile;
  final List<SnapLine> activeLines;
  final bool xEdgeSnapped;
  final bool yEdgeSnapped;
  final bool xAlignmentApplied;
  final bool yAlignmentApplied;

  const SnapResult({
    required this.tile,
    required this.activeLines,
    this.xEdgeSnapped = false,
    this.yEdgeSnapped = false,
    this.xAlignmentApplied = false,
    this.yAlignmentApplied = false,
  });
}

/// Pure geometric helpers for monitor layout: snapping, overlap detection,
/// viewport projection and total bandwidth estimation. No Flutter widget
/// dependencies — easily unit-testable.
class LayoutMath {
  LayoutMath._();

  /// Snaps the top-left corner of [m] to the closest matching edge of any
  /// monitor in [all] (excluding itself), within [threshold]. When an axis
  /// snap engages and the corresponding alignment switch is on, the *other*
  /// axis is additionally snapped to one of three alignment options
  /// (top/center/bottom or left/center/right) of the neighbour. Edge snap
  /// is always honoured (no-overlap / no-gap guarantee); alignment is the
  /// switchable behaviour that callers turn off when the user has clearly
  /// escaped it.
  static SnapResult snapToEdges(
    MonitorTileData m,
    Iterable<MonitorTileData> all,
    double threshold, {
    bool xAlignmentEnabled = true,
    bool yAlignmentEnabled = true,
  }) {
    double newX = m.x;
    double newY = m.y;
    final lines = <SnapLine>[];
    bool xEdge = false;
    bool yEdge = false;
    bool yAlignApplied = false;
    bool xAlignApplied = false;
    final width = m.width / m.scale;
    final height = m.height / m.scale;

    for (final other in all) {
      if (other.id == m.id) continue;
      final oLeft = other.x;
      final oRight = other.x + other.width / other.scale;
      final oTop = other.y;
      final oBottom = other.y + other.height / other.scale;

      // ── Vertical (X-axis) edge snaps ────────────────────────────────────
      bool xSnapped = false;
      if ((newX - oRight).abs() <= threshold) {
        newX = oRight;
        xSnapped = true;
        xEdge = true;
        lines.add(SnapLine(
          x1: oRight, y1: oTop, x2: oRight, y2: oBottom,
          axis: SnapAxis.vertical,
        ));
      } else if ((newX + width - oLeft).abs() <= threshold) {
        newX = oLeft - width;
        xSnapped = true;
        xEdge = true;
        lines.add(SnapLine(
          x1: oLeft, y1: oTop, x2: oLeft, y2: oBottom,
          axis: SnapAxis.vertical,
        ));
      }
      if (xSnapped && yAlignmentEnabled) {
        // Try Y-axis alignment: top, bottom, center.
        final candidates = <_AlignCandidate>[
          _AlignCandidate(target: oTop, newPos: oTop, type: _AlignType.top),
          _AlignCandidate(
              target: oBottom,
              newPos: oBottom - height,
              type: _AlignType.bottom),
          _AlignCandidate(
              target: (oTop + oBottom) / 2,
              newPos: (oTop + oBottom) / 2 - height / 2,
              type: _AlignType.center),
        ];
        _AlignCandidate? best;
        var bestDist = double.infinity;
        for (final c in candidates) {
          final dist = c.type == _AlignType.top
              ? (newY - c.target).abs()
              : c.type == _AlignType.bottom
                  ? (newY + height - c.target).abs()
                  : (newY + height / 2 - c.target).abs();
          if (dist <= threshold && dist < bestDist) {
            best = c;
            bestDist = dist;
          }
        }
        if (best != null) {
          newY = best.newPos;
          yAlignApplied = true;
          // Horizontal guide line at the alignment level.
          final guideY = best.type == _AlignType.top
              ? oTop
              : best.type == _AlignType.bottom
                  ? oBottom
                  : (oTop + oBottom) / 2;
          final lineLeft = newX < oLeft ? newX : oLeft;
          final lineRight = (newX + width) > oRight ? (newX + width) : oRight;
          lines.add(SnapLine(
            x1: lineLeft, y1: guideY, x2: lineRight, y2: guideY,
            axis: SnapAxis.horizontal,
          ));
        }
      }

      // ── Horizontal (Y-axis) edge snaps ──────────────────────────────────
      bool ySnapped = false;
      if ((newY - oBottom).abs() <= threshold) {
        newY = oBottom;
        ySnapped = true;
        yEdge = true;
        lines.add(SnapLine(
          x1: oLeft, y1: oBottom, x2: oRight, y2: oBottom,
          axis: SnapAxis.horizontal,
        ));
      } else if ((newY + height - oTop).abs() <= threshold) {
        newY = oTop - height;
        ySnapped = true;
        yEdge = true;
        lines.add(SnapLine(
          x1: oLeft, y1: oTop, x2: oRight, y2: oTop,
          axis: SnapAxis.horizontal,
        ));
      }
      if (ySnapped && !xSnapped && xAlignmentEnabled) {
        // Try X-axis alignment: left, right, center.
        final candidates = <_AlignCandidate>[
          _AlignCandidate(target: oLeft, newPos: oLeft, type: _AlignType.top),
          _AlignCandidate(
              target: oRight,
              newPos: oRight - width,
              type: _AlignType.bottom),
          _AlignCandidate(
              target: (oLeft + oRight) / 2,
              newPos: (oLeft + oRight) / 2 - width / 2,
              type: _AlignType.center),
        ];
        _AlignCandidate? best;
        var bestDist = double.infinity;
        for (final c in candidates) {
          final dist = c.type == _AlignType.top
              ? (newX - c.target).abs()
              : c.type == _AlignType.bottom
                  ? (newX + width - c.target).abs()
                  : (newX + width / 2 - c.target).abs();
          if (dist <= threshold && dist < bestDist) {
            best = c;
            bestDist = dist;
          }
        }
        if (best != null) {
          newX = best.newPos;
          xAlignApplied = true;
          final guideX = best.type == _AlignType.top
              ? oLeft
              : best.type == _AlignType.bottom
                  ? oRight
                  : (oLeft + oRight) / 2;
          final lineTop = newY < oTop ? newY : oTop;
          final lineBottom =
              (newY + height) > oBottom ? (newY + height) : oBottom;
          lines.add(SnapLine(
            x1: guideX, y1: lineTop, x2: guideX, y2: lineBottom,
            axis: SnapAxis.vertical,
          ));
        }
      }
    }
    return SnapResult(
      tile: m.copyWith(x: newX, y: newY),
      activeLines: lines,
      xEdgeSnapped: xEdge,
      yEdgeSnapped: yEdge,
      xAlignmentApplied: xAlignApplied,
      yAlignmentApplied: yAlignApplied,
    );
  }

  /// True if [updated] (placed at index [idx] in [all]) overlaps any other
  /// monitor in [all]. Uses logical (post-scale) rectangles.
  static bool hasOverlap(
    MonitorTileData updated,
    List<MonitorTileData> all,
    int idx,
  ) {
    final a = Rect.fromLTWH(
      updated.x,
      updated.y,
      updated.width / updated.scale,
      updated.height / updated.scale,
    );
    for (var i = 0; i < all.length; i++) {
      if (i == idx) continue;
      final o = all[i];
      final b = Rect.fromLTWH(
        o.x,
        o.y,
        o.width / o.scale,
        o.height / o.scale,
      );
      if (a.overlaps(b)) return true;
    }
    return false;
  }

  /// Projects the absolute monitor layout into [viewport] coordinates so it
  /// fits within 80 % of the viewport (centered). Returns a [DisplayLayout]
  /// with the chosen scale/offset and the projected monitor rectangles.
  ///
  /// When [pinnedBounds] is supplied, it overrides the auto-computed
  /// bounding box (left/top/right/bottom in absolute monitor space). This
  /// lets the UI freeze the canvas while a drag is in progress so the
  /// non-dragged tiles do not slide around as the dragged tile pushes the
  /// bounding box outward — without this, dragging a monitor above origin
  /// (negative Y) reflows the whole layout each frame and the tiles appear
  /// to overlap and ghost.
  static DisplayLayout computeDisplay(
    List<MonitorTileData> mons,
    Size viewport, {
    Rect? pinnedBounds,
  }) {
    if (mons.isEmpty) return DisplayLayout.empty;

    final double minX;
    final double minY;
    final double maxX;
    final double maxY;
    if (pinnedBounds != null) {
      minX = pinnedBounds.left;
      minY = pinnedBounds.top;
      maxX = pinnedBounds.right;
      maxY = pinnedBounds.bottom;
    } else {
      minX = mons.map((m) => m.x).reduce(min);
      minY = mons.map((m) => m.y).reduce(min);
      maxX = mons.map((m) => m.x + m.width / m.scale).reduce(max);
      maxY = mons.map((m) => m.y + m.height / m.scale).reduce(max);
    }

    final boundingWidth = maxX - minX;
    final boundingHeight = maxY - minY;

    final allowedW = viewport.width * 0.8;
    final allowedH = viewport.height * 0.8;

    final scaleX = boundingWidth == 0 ? 1.0 : allowedW / boundingWidth;
    final scaleY = boundingHeight == 0 ? 1.0 : allowedH / boundingHeight;
    var scaleFactor = min(scaleX, scaleY);
    if (scaleFactor > 1.0) scaleFactor = 1.0;

    final scaledBW = boundingWidth * scaleFactor;
    final scaledBH = boundingHeight * scaleFactor;
    final offsetX = (viewport.width - scaledBW) / 2;
    final offsetY = (viewport.height - scaledBH) / 2;

    final displayMonitors = mons.map((m) {
      final dx = (m.x - minX) * scaleFactor + offsetX;
      final dy = (m.y - minY) * scaleFactor + offsetY;
      final dw = (m.width / m.scale) * scaleFactor;
      final dh = (m.height / m.scale) * scaleFactor;
      return m.copyWith(x: dx, y: dy, width: dw, height: dh);
    }).toList();

    return DisplayLayout(
      scaleFactor: scaleFactor,
      offsetX: offsetX,
      offsetY: offsetY,
      originX: minX,
      originY: minY,
      displayMonitors: displayMonitors,
    );
  }

  /// Computes the bounding box of [mons] in absolute monitor space — the
  /// same one [computeDisplay] would derive when no pin is supplied. Used
  /// by callers (e.g. the controller) that want to snapshot the bounds at
  /// drag start and feed them back as [computeDisplay]'s [pinnedBounds].
  static Rect boundingBox(Iterable<MonitorTileData> mons) {
    final list = mons.toList(growable: false);
    if (list.isEmpty) return Rect.zero;
    final minX = list.map((m) => m.x).reduce(min);
    final minY = list.map((m) => m.y).reduce(min);
    final maxX = list.map((m) => m.x + m.width / m.scale).reduce(max);
    final maxY = list.map((m) => m.y + m.height / m.scale).reduce(max);
    return Rect.fromLTRB(minX, minY, maxX, maxY);
  }

  /// Sum of width × height × refresh across all enabled monitors. Used for
  /// the bandwidth-warning heuristic. Disabled monitors are ignored.
  static double totalPixelRate(Iterable<MonitorTileData> mons) {
    var sum = 0.0;
    for (final m in mons.where((m) => m.enabled)) {
      sum += m.width * m.height * (m.refresh > 0 ? m.refresh : 60);
    }
    return sum;
  }
}

enum _AlignType { top, bottom, center }

class _AlignCandidate {
  final double target;
  final double newPos;
  final _AlignType type;
  const _AlignCandidate({
    required this.target,
    required this.newPos,
    required this.type,
  });
}
