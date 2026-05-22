import 'package:flutter/material.dart';

/// The editor canvas backdrop: a deep, subtly-tinted dark gradient with a
/// faint dot grid painted over it, so the area reads as a coordinate space
/// the monitors live in rather than a flat black void.
///
/// Childless on purpose — it's meant to sit in a [RepaintBoundary] behind the
/// draggable tiles (a `Positioned.fill` layer), so dragging a monitor never
/// repaints this static grid.
class DotGridBackground extends StatelessWidget {
  /// Accent used for the very subtle tint. Usually the app accent.
  final Color accent;

  const DotGridBackground({super.key, required this.accent});

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            const Color(0xFF14171C),
            Color.alphaBlend(
                accent.withValues(alpha: 0.05), const Color(0xFF0D0F12)),
          ],
        ),
      ),
      child: CustomPaint(
        size: Size.infinite,
        painter: _DotGridPainter(dotColor: Colors.white.withValues(alpha: 0.05)),
      ),
    );
  }
}

class _DotGridPainter extends CustomPainter {
  final Color dotColor;
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
