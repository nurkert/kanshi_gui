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
  final List<MonitorTileData> displayMonitors;

  const DisplayLayout({
    required this.scaleFactor,
    required this.offsetX,
    required this.offsetY,
    required this.displayMonitors,
  });

  static const empty = DisplayLayout(
    scaleFactor: 1.0,
    offsetX: 0.0,
    offsetY: 0.0,
    displayMonitors: <MonitorTileData>[],
  );
}

/// Pure geometric helpers for monitor layout: snapping, overlap detection,
/// viewport projection and total bandwidth estimation. No Flutter widget
/// dependencies — easily unit-testable.
class LayoutMath {
  LayoutMath._();

  /// Returns a copy of [m] whose top-left corner is snapped to the closest
  /// matching edge of any monitor in [all] (excluding itself), if within
  /// [threshold]. Snaps independently on the x and y axes.
  static MonitorTileData snapToEdges(
    MonitorTileData m,
    Iterable<MonitorTileData> all,
    double threshold,
  ) {
    double newX = m.x;
    double newY = m.y;
    for (final other in all) {
      if (other.id == m.id) continue;
      final left = m.x;
      final right = m.x + m.width / m.scale;
      final top = m.y;
      final bottom = m.y + m.height / m.scale;
      final oLeft = other.x;
      final oRight = other.x + other.width / other.scale;
      final oTop = other.y;
      final oBottom = other.y + other.height / other.scale;

      if ((left - oRight).abs() <= threshold) newX = oRight;
      if ((right - oLeft).abs() <= threshold) {
        newX = oLeft - m.width / m.scale;
      }
      if ((top - oBottom).abs() <= threshold) newY = oBottom;
      if ((bottom - oTop).abs() <= threshold) {
        newY = oTop - m.height / m.scale;
      }
    }
    return m.copyWith(x: newX, y: newY);
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
  static DisplayLayout computeDisplay(
    List<MonitorTileData> mons,
    Size viewport,
  ) {
    if (mons.isEmpty) return DisplayLayout.empty;

    final minX = mons.map((m) => m.x).reduce(min);
    final minY = mons.map((m) => m.y).reduce(min);
    final maxX = mons.map((m) => m.x + m.width / m.scale).reduce(max);
    final maxY = mons.map((m) => m.y + m.height / m.scale).reduce(max);

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
      displayMonitors: displayMonitors,
    );
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
