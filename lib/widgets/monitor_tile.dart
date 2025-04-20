import 'package:flutter/material.dart';
import '../models/monitor_tile_data.dart';

/// Draggable, rotatable visual representation of a monitor.
class MonitorTile extends StatefulWidget {
  final MonitorTileData data;
  final bool exists;
  final double snapThreshold;
  final Size containerSize;
  final double scaleFactor;
  final double offsetX;
  final double offsetY;
  final VoidCallback? onDragStart;
  final Function(MonitorTileData) onUpdate;
  final VoidCallback onDragEnd;

  const MonitorTile({
    Key? key,
    required this.data,
    required this.exists,
    required this.snapThreshold,
    required this.containerSize,
    required this.scaleFactor,
    required this.offsetX,
    required this.offsetY,
    this.onDragStart,
    required this.onUpdate,
    required this.onDragEnd,
  }) : super(key: key);

  @override
  _MonitorTileState createState() => _MonitorTileState();
}

class _MonitorTileState extends State<MonitorTile> {
  late Offset _pos;

  @override
  void initState() {
    super.initState();
    _pos = Offset(widget.data.x, widget.data.y);
  }

  @override
  void didUpdateWidget(MonitorTile old) {
    super.didUpdateWidget(old);
    _pos = Offset(widget.data.x, widget.data.y);
  }

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: _pos.dx,
      top: _pos.dy,
      width: widget.data.width,
      height: widget.data.height,
      child: GestureDetector(
        onPanStart: (_) => widget.onDragStart?.call(),
        onPanUpdate: (d) {
          setState(() => _pos += d.delta);
          widget.onUpdate(widget.data.copyWith(x: _pos.dx, y: _pos.dy));
        },
        onPanEnd: (_) => widget.onDragEnd(),
        onSecondaryTap: () {
          final newRot = (widget.data.rotation + 90) % 360;
          widget.onUpdate(widget.data.copyWith(rotation: newRot));
        },
        child: Container(
          decoration: BoxDecoration(
            border: Border.all(
              color: widget.exists ? Colors.green : Colors.red,
              width: 2,
            ),
          ),
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  widget.data.manufacturer,
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                Text(widget.data.resolution),
                Text("\${widget.data.orientation} (\${widget.data.rotation}°)"),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
