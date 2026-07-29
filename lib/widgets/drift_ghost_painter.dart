import 'package:flutter/material.dart';
import 'package:kanshi_gui/design/tokens.dart';
import 'package:kanshi_gui/models/monitor_tile_data.dart';
import 'package:kanshi_gui/services/layout_math.dart';

/// Draws, for each screen that is not where the saved setup says it should
/// be, a dashed outline at the position it is *actually* occupying.
///
/// Drift used to be a banner: a sentence like "DP-1: expected (1920, 0) but is
/// at (6560, 0)", floating over the canvas above another banner. The canvas
/// already shows positions — that is its entire job — so the honest way to say
/// a screen moved is to show it moved. The solid tile stays where the setup
/// wants it; the ghost shows where it went.
class DriftGhostPainter extends CustomPainter {
  /// The live outputs whose position disagrees with the active setup.
  final List<MonitorTileData> drifted;

  /// The projection used for the solid tiles, so the ghosts land in the same
  /// coordinate space rather than a subtly different one.
  final DisplayLayout layout;

  final Color color;

  const DriftGhostPainter({
    required this.drifted,
    required this.layout,
    required this.color,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (drifted.isEmpty) return;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = Borders.ghost
      ..color = color;

    for (final m in drifted) {
      final rect = _project(m);
      _drawDashed(canvas, rect, paint);
    }
  }

  Rect _project(MonitorTileData m) {
    final left = layout.offsetX + (m.x - layout.originX) * layout.scaleFactor;
    final top = layout.offsetY + (m.y - layout.originY) * layout.scaleFactor;
    final scale = m.scale == 0 ? 1.0 : m.scale;
    return Rect.fromLTWH(
      left,
      top,
      m.width / scale * layout.scaleFactor,
      m.height / scale * layout.scaleFactor,
    );
  }

  void _drawDashed(Canvas canvas, Rect rect, Paint paint) {
    const dash = Borders.ghostDash;
    const gap = Borders.ghostGap;
    void line(Offset a, Offset b) {
      final total = (b - a).distance;
      if (total <= 0) return;
      final dir = (b - a) / total;
      var travelled = 0.0;
      while (travelled < total) {
        final end = (travelled + dash).clamp(0.0, total);
        canvas.drawLine(a + dir * travelled, a + dir * end, paint);
        travelled = end + gap;
      }
    }

    line(rect.topLeft, rect.topRight);
    line(rect.topRight, rect.bottomRight);
    line(rect.bottomRight, rect.bottomLeft);
    line(rect.bottomLeft, rect.topLeft);
  }

  @override
  bool shouldRepaint(DriftGhostPainter old) =>
      old.color != color ||
      old.layout.scaleFactor != layout.scaleFactor ||
      old.layout.offsetX != layout.offsetX ||
      old.layout.offsetY != layout.offsetY ||
      old.drifted.length != drifted.length ||
      !_sameRects(old.drifted, drifted);

  bool _sameRects(List<MonitorTileData> a, List<MonitorTileData> b) {
    for (var i = 0; i < a.length; i++) {
      if (a[i].id != b[i].id || a[i].x != b[i].x || a[i].y != b[i].y) {
        return false;
      }
    }
    return true;
  }
}
