import 'package:flutter/material.dart';

/// The editor canvas backdrop: a deep, subtly-tinted dark gradient with a
/// faint dot grid painted over it, so the area reads as a coordinate space
/// the monitors live in rather than a flat black void. Purely decorative —
/// it sits behind the snap lines and the draggable tiles and never
/// intercepts pointer events.
class DotGridBackground extends StatelessWidget {
  /// Accent used for the very subtle corner glow. Usually the app accent.
  final Color accent;
  final Widget child;

  const DotGridBackground({
    super.key,
    required this.accent,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            const Color(0xFF14171C),
            Color.alphaBlend(accent.withValues(alpha: 0.05), const Color(0xFF0D0F12)),
          ],
        ),
      ),
      child: CustomPaint(
        painter: _DotGridPainter(
          dotColor: Colors.white.withValues(alpha: 0.05),
        ),
        child: child,
      ),
    );
  }
}

class _DotGridPainter extends CustomPainter {
  final Color dotColor;
  static const double _spacing = 28;
  static const double _radius = 1.1;

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
