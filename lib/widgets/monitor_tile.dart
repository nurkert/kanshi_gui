// lib/widgets/monitor_tile.dart

import 'package:flutter/material.dart';
import 'dart:math';
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
    Key? key,
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
  }) : super(key: key);

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
    return Positioned(
      left: position.dx,
      top: position.dy,
      width: widget.data.width,
      height: widget.data.height,
      child: GestureDetector(
        onPanStart: (_) {
          if (widget.onDragStart != null) {
            widget.onDragStart!();
          }
        },
        onPanUpdate: (details) {
          setState(() {
            position += details.delta;
          });
          // Melden neue Position an den Parent
          widget.onUpdate(
            widget.data.copyWith(
              x: position.dx,
              y: position.dy,
            ),
          );
        },
        onPanEnd: (_) {
          widget.onDragEnd();
        },
        onSecondaryTap: () {
          // Drehe um +90°
          final newRotation = (widget.data.rotation + 90) % 360;
          widget.onUpdate(widget.data.copyWith(rotation: newRotation));
        },
        child: Container(
          decoration: BoxDecoration(
            border: Border.all(
              color: widget.exists ? Colors.green : Colors.red,
              width: 2,
            ),
          ),
          // Wir machen hier kein Transform.rotate mehr,
          // sondern zeigen den Text normal an.
          // Die "Rotation" wird stattdessen in width/height gespiegelt (siehe HomePage).
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  widget.data.id,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  widget.data.resolution,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 14),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  // z.B. "landscape" oder "portrait" oder "rotation=90"
                  // Kannst du anpassen wie du willst
                  "${widget.data.orientation} (${widget.data.rotation}°)",
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 14),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
