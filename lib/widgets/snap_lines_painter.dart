import 'package:flutter/material.dart';
import 'package:kanshi_gui/services/layout_math.dart';
import 'dart:math' as math;

/// Paints Figma-style snap guide lines on top of the layout canvas while a
/// drag is in progress. The lines arrive in *absolute* monitor space
/// (matching the coordinate system the [KanshiController] uses internally)
/// and are projected into viewport coordinates via the same origin/scale
/// the layout itself used (carried on [DisplayLayout]).
class SnapLinesPainter extends CustomPainter {
  final List<SnapLine> lines;
  final DisplayLayout layout;
  /// Optional accent colour — when non-null, the guides paint in this
  /// hue (with a fixed 0.85 alpha) so they pick up the user's sway
  /// `client.focused` border colour. Null falls back to the original
  /// material-blue (`#4FC3F7`).
  final Color? accent;

  const SnapLinesPainter({
    required this.lines,
    required this.layout,
    this.accent,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (lines.isEmpty) return;
    final base = accent ?? const Color(0xFF4FC3F7);
    final paint = Paint()
      ..color = base.withValues(alpha: 0.85)
      ..strokeWidth = 2.0
      ..style = PaintingStyle.stroke;

    for (final line in lines) {
      final x1 =
          (line.x1 - layout.originX) * layout.scaleFactor + layout.offsetX;
      final y1 =
          (line.y1 - layout.originY) * layout.scaleFactor + layout.offsetY;
      final x2 =
          (line.x2 - layout.originX) * layout.scaleFactor + layout.offsetX;
      final y2 =
          (line.y2 - layout.originY) * layout.scaleFactor + layout.offsetY;
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
      old.lines != lines || old.layout != layout || old.accent != accent;
}
