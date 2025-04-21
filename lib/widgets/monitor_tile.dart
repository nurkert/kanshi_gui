import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:kanshi_gui/models/monitor_tile_data.dart';

/// Ein visuelles Rechteck, das man per Drag verschieben kann.
/// Rechtsklick (onSecondaryTap) erhöht rotation um +90°.
class MonitorTile extends StatefulWidget {
  final MonitorTileData data;    // bereits auf die UI-Scale heruntergerechnete Koordinaten
  final bool exists;
  final double snapThreshold;
  final Size containerSize;
  final double scaleFactor;
  final double offsetX;
  final double offsetY;
  final double originX;
  final double originY;

  final Function(MonitorTileData) onUpdate; // beim Drag oder Rotation
  final VoidCallback onDragEnd;             
  final Function()? onDragStart;           

  const MonitorTile({
    super.key,
    required this.data,
    required this.exists,
    required this.snapThreshold,
    required this.containerSize,
    required this.scaleFactor,
    required this.offsetX,
    required this.offsetY,
    required this.originX,
    required this.originY,
    required this.onUpdate,
    required this.onDragEnd,
    this.onDragStart,
  });

  @override
  _MonitorTileState createState() => _MonitorTileState();
}

class _MonitorTileState extends State<MonitorTile> {
  late Offset position; // Position innerhalb der Stack (skaliert)

  @override
  void initState() {
    super.initState();
    position = Offset(widget.data.x, widget.data.y);
  }

  @override
  void didUpdateWidget(MonitorTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Falls sich die Koordinaten ändern, aktualisieren wir die Position.
    position = Offset(widget.data.x, widget.data.y);
  }

  @override
  Widget build(BuildContext context) {
    // Name ohne die letzten zwei Worte
    final parts = widget.data.manufacturer.split(' ');
    final displayName = parts.length > 2
        ? parts.sublist(0, parts.length - 2).join(' ')
        : widget.data.manufacturer;

    return Positioned(
      left: position.dx,
      top: position.dy,
      width: widget.data.width,
      height: widget.data.height,
      child: GestureDetector(
        onPanStart: (_) => widget.onDragStart?.call(),
        onPanUpdate: (details) {
          setState(() => position += details.delta);
          widget.onUpdate(widget.data.copyWith(
            x: position.dx,
            y: position.dy,
          ));
        },
        onPanEnd: (_) => widget.onDragEnd(),
        onSecondaryTap: () {
          final newRotation = (widget.data.rotation + 90) % 360;
          widget.onUpdate(widget.data.copyWith(rotation: newRotation));
        },
        child: ClipRRect(
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 5, sigmaY: 5),
            child: Container(
              decoration: BoxDecoration(
                color: (widget.exists
                        ? Colors.green.withOpacity(0.3)
                        : Colors.red.withOpacity(0.3)),
                border: Border.all(
                  color: widget.exists ? Colors.greenAccent : Colors.redAccent,
                  width: 2,
                ),
              ),
              padding: const EdgeInsets.all(8),
              child: Center(
                child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(
                      displayName,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                      ),
                      softWrap: true,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    widget.data.resolution,
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 14),
                  ),
                  Text(
                    "${widget.data.orientation} (${widget.data.rotation}°)",
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 14),
                  ),
                ],
              )
              ),
            ),
          ),
        ),
      ),
    );
  }
}
