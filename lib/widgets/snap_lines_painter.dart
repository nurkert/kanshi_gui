import 'package:flutter/material.dart';
import 'package:kanshi_gui/services/layout_math.dart';
import 'package:kanshi_gui/models/monitor_tile_data.dart';
import 'dart:math' as math;

/// Paints Figma-style snap guide lines on top of the layout canvas while a
/// drag is in progress. The lines arrive in *absolute* monitor space
/// (matching the coordinate system the [KanshiController] uses internally)
/// and are projected into viewport coordinates via the same min/scale
/// mapping that [LayoutMath.computeDisplay] applied to the tiles.
class SnapLinesPainter extends CustomPainter {
  final List<SnapLine> lines;
  final DisplayLayout layout;
  final List<MonitorTileData> referenceMonitors;

  const SnapLinesPainter({
    required this.lines,
    required this.layout,
    required this.referenceMonitors,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (lines.isEmpty || referenceMonitors.isEmpty) return;
    final minX =
        referenceMonitors.map((m) => m.x).reduce((a, b) => a < b ? a : b);
    final minY =
        referenceMonitors.map((m) => m.y).reduce((a, b) => a < b ? a : b);
    final paint = Paint()
      ..color = const Color(0xFF4FC3F7).withValues(alpha: 0.85)
      ..strokeWidth = 2.0
      ..style = PaintingStyle.stroke;

    for (final line in lines) {
      final x1 = (line.x1 - minX) * layout.scaleFactor + layout.offsetX;
      final y1 = (line.y1 - minY) * layout.scaleFactor + layout.offsetY;
      final x2 = (line.x2 - minX) * layout.scaleFactor + layout.offsetX;
      final y2 = (line.y2 - minY) * layout.scaleFactor + layout.offsetY;
      // Extend each guide line by 12 px on either side so it visibly
      // overshoots the snapped edges (looks like a real alignment guide).
      const overhang = 12.0;
      if (line.axis == SnapAxis.vertical) {
        canvas.drawLine(
          Offset(x1, math.min(y1, y2) - overhang),
          Offset(x2, math.max(y1, y2) + overhang),
          paint,
        );
      } else {
        canvas.drawLine(
          Offset(math.min(x1, x2) - overhang, y1),
          Offset(math.max(x1, x2) + overhang, y2),
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant SnapLinesPainter old) =>
      old.lines != lines ||
      old.layout != layout ||
      old.referenceMonitors != referenceMonitors;
}
