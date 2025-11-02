import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:kanshi_gui/models/monitor_tile_data.dart';
import 'package:kanshi_gui/models/monitor_mode.dart';

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
  final double originalWidth;
  final double originalHeight;

  final Function(MonitorTileData) onUpdate; // beim Drag oder Rotation
  final VoidCallback onDragEnd;
  final Function()? onDragStart;
  final ValueChanged<double>? onScale;
  final ValueChanged<MonitorMode>? onModeChange;
  final ValueChanged<bool>? onToggleEnabled;

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
    required this.originalWidth,
    required this.originalHeight,
    required this.onUpdate,
    required this.onDragEnd,
    this.onDragStart,
    this.onScale,
    this.onModeChange,
    this.onToggleEnabled,
  });

  @override
  _MonitorTileState createState() => _MonitorTileState();
}

class _MonitorTileState extends State<MonitorTile> {
  late Offset position; // Position innerhalb der Stack (skaliert)
  late double tileWidth;
  late double tileHeight;

  @override
  void initState() {
    super.initState();
    position = Offset(widget.data.x, widget.data.y);
    tileWidth = widget.data.width;
    tileHeight = widget.data.height;
  }

  @override
  void didUpdateWidget(MonitorTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Falls sich die Koordinaten ändern, aktualisieren wir die Position.
    position = Offset(widget.data.x, widget.data.y);
    tileWidth = widget.data.width;
    tileHeight = widget.data.height;
  }

  @override
  Widget build(BuildContext context) {
    // Name ohne die letzten zwei Worte
    final parts = widget.data.manufacturer.split(' ');
    final displayName = parts.length > 2
        ? parts.sublist(0, parts.length - 2).join(' ')
        : widget.data.manufacturer;

    final isEnabled = widget.data.enabled;
    final backgroundColor = isEnabled
        ? (widget.exists
            ? Colors.green.withOpacity(0.3)
            : Colors.red.withOpacity(0.3))
        : Colors.grey.withOpacity(0.4);
    final borderColor = isEnabled
        ? (widget.exists ? Colors.greenAccent : Colors.redAccent)
        : Colors.grey;
    final textColor = isEnabled ? Colors.white : Colors.white70;

    return Positioned(
      left: position.dx,
      top: position.dy,
      width: tileWidth,
      height: tileHeight,
      child: Stack(
        children: [
          GestureDetector(
            onPanStart: isEnabled ? (_) => widget.onDragStart?.call() : null,
            onPanUpdate: isEnabled
                ? (details) {
                    setState(() => position += details.delta);
                    widget.onUpdate(
                      widget.data.copyWith(
                        x: position.dx,
                        y: position.dy,
                      ),
                    );
                  }
                : null,
            onPanEnd: isEnabled ? (_) => widget.onDragEnd() : null,
            onSecondaryTap: isEnabled
                ? () {
                    final newRotation =
                        (widget.data.rotation + 90) % 360;
                    widget.onUpdate(
                      widget.data.copyWith(rotation: newRotation),
                    );
                  }
                : null,
            child: ClipRRect(
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 5, sigmaY: 5),
                child: Container(
                  decoration: BoxDecoration(
                    color: backgroundColor,
                    border: Border.all(
                      color: borderColor,
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
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 16,
                              color: textColor,
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
                          style: TextStyle(fontSize: 14, color: textColor),
                        ),
                        Text(
                          "${widget.data.orientation} (${widget.data.rotation}°)",
                          textAlign: TextAlign.center,
                          style: TextStyle(fontSize: 14, color: textColor),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            right: 0,
            bottom: 0,
            child: MouseRegion(
              cursor: SystemMouseCursors.resizeUpLeftDownRight,
              child: GestureDetector(
                onPanUpdate: isEnabled
                    ? (details) {
                        setState(() {
                          tileWidth += details.delta.dx;
                          tileHeight += details.delta.dy;
                          if (tileWidth < 20) tileWidth = 20;
                          if (tileHeight < 20) tileHeight = 20;
                        });
                        var newScale = widget.originalWidth /
                            ((tileWidth) / widget.scaleFactor);
                        for (int n = 1; n <= 8; n++) {
                          if ((newScale - n).abs() < 0.05) {
                            newScale = n.toDouble();
                            tileWidth = widget.originalWidth /
                                newScale * widget.scaleFactor;
                            tileHeight = widget.originalHeight /
                                newScale * widget.scaleFactor;
                            break;
                          }
                        }
                        newScale =
                            double.parse(newScale.toStringAsFixed(2));
                        widget.onScale?.call(newScale);
                      }
                    : null,
                child: Container(
                  width: 16,
                  height: 16,
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.5),
                    border: Border.all(color: Colors.black),
                  ),
                ),
              ),
            ),
          ),
          if (widget.data.modes.isNotEmpty || widget.onToggleEnabled != null)
            Positioned(
              right: 0,
              top: 0,
              child: MenuAnchor(
                builder: (context, controller, child) {
                  return IconButton(
                    padding: EdgeInsets.zero,
                    icon: Icon(Icons.more_vert, size: 16, color: textColor),
                    onPressed: () {
                      if (controller.isOpen) {
                        controller.close();
                      } else {
                        controller.open();
                      }
                    },
                  );
                },
                menuChildren: [
                  if (widget.onToggleEnabled != null)
                    MenuItemButton(
                      onPressed: () =>
                          widget.onToggleEnabled!.call(!widget.data.enabled),
                      leadingIcon: Icon(
                        widget.data.enabled
                            ? Icons.visibility_off
                            : Icons.visibility,
                      ),
                      child: Text(
                        widget.data.enabled
                            ? 'Display deaktivieren'
                            : 'Display aktivieren',
                      ),
                    ),
                  if (widget.data.modes.isNotEmpty)
                    SubmenuButton(
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text('Auflösung'),
                          SizedBox(width: 8),
                          Icon(Icons.chevron_right, size: 16),
                        ],
                      ),
                      menuChildren: [
                        for (final m in widget.data.modes)
                          MenuItemButton(
                            onPressed: widget.onModeChange != null &&
                                    widget.data.enabled
                                ? () => widget.onModeChange!(m)
                                : null,
                            child: Text(m.label),
                          ),
                      ],
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
