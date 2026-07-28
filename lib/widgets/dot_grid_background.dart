import 'package:flutter/material.dart';
import 'package:kanshi_gui/design/theme_context.dart';

/// The canvas backdrop.
///
/// A flat field with a faint dot grid, so the area reads as a coordinate
/// space the screens stand in rather than a decorated panel. It used to be an
/// accent-tinted diagonal gradient between two hardcoded near-blacks, which
/// meant the canvas — the largest surface in the window — stayed dark in the
/// light theme no matter what the setting said.
///
/// Childless on purpose: it sits in a [RepaintBoundary] behind the draggable
/// tiles, so dragging a screen never repaints the grid.
class DotGridBackground extends StatelessWidget {
  const DotGridBackground({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return ColoredBox(
      color: c.bg,
      child: CustomPaint(
        size: Size.infinite,
        painter: _DotGridPainter(dotColor: c.hairline),
      ),
    );
  }
}

class _DotGridPainter extends CustomPainter {
  final Color dotColor;

  /// One dot per 32 logical pixels: close enough to read as a grid, far
  /// enough not to compete with the screens standing on it.
  static const double _spacing = 32;
  static const double _radius = 1.0;

  _DotGridPainter({required this.dotColor});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = dotColor;
    for (double y = _spacing / 2; y < size.height; y += _spacing) {
      for (double x = _spacing / 2; x < size.width; x += _spacing) {
        canvas.drawCircle(Offset(x, y), _radius, paint);
      }
    }
  }

  @override
  bool shouldRepaint(_DotGridPainter oldDelegate) =>
      oldDelegate.dotColor != dotColor;
}
