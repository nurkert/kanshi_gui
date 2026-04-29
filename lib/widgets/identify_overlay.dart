import 'package:flutter/material.dart';

/// 3-second pulsing overlay that draws a large numeric identifier on top
/// of a [MonitorTile]. Used by the "Identify Displays" affordance — the
/// tile arrangement matches the physical layout, so the user can map
/// number ↔ monitor at a glance.
class IdentifyOverlay extends StatefulWidget {
  final int number;
  final Color accent;
  final VoidCallback? onFinished;
  const IdentifyOverlay({
    super.key,
    required this.number,
    this.accent = const Color(0xFF4FC3F7),
    this.onFinished,
  });

  @override
  State<IdentifyOverlay> createState() => _IdentifyOverlayState();
}

class _IdentifyOverlayState extends State<IdentifyOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctl;

  @override
  void initState() {
    super.initState();
    _ctl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 700))
      ..repeat(reverse: true);
    Future.delayed(const Duration(seconds: 3), () {
      if (!mounted) return;
      widget.onFinished?.call();
    });
  }

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: AnimatedBuilder(
        animation: _ctl,
        builder: (context, _) {
          final t = _ctl.value;
          return Container(
            decoration: BoxDecoration(
              color: widget.accent.withValues(alpha: 0.15 + 0.20 * t),
              border: Border.all(
                color: widget.accent.withValues(alpha: 0.7 + 0.3 * t),
                width: 4,
              ),
            ),
            child: Center(
              child: Text(
                '${widget.number}',
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.85 + 0.15 * t),
                  fontSize: 96,
                  fontWeight: FontWeight.w800,
                  shadows: const [
                    Shadow(
                      blurRadius: 8,
                      color: Colors.black54,
                      offset: Offset(0, 2),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
