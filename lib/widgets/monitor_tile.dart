import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:kanshi_gui/models/monitor_tile_data.dart';
import 'package:kanshi_gui/models/monitor_mode.dart';
import 'package:kanshi_gui/widgets/identify_overlay.dart';
import 'package:collection/collection.dart';

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
  /// Live scale changes during a resize drag. May fire many times — UI
  /// updates only, no compositor calls.
  final ValueChanged<double>? onScale;
  /// Final commit on resize-handle release. The controller raster the value
  /// onto a snap entry here.
  final ValueChanged<double>? onScaleCommit;
  final ValueChanged<MonitorMode>? onModeChange;
  final ValueChanged<bool>? onToggleEnabled;
  final VoidCallback? onCustomMode;
  final VoidCallback? onCustomModeRevert;
  final int? identifyNumber;
  /// When non-null the three-dot menu offers a "Mirror onto …" submenu
  /// (and a "Stop mirroring" item if this tile already has [data.mirrorOf]
  /// set). The HomePage only wires this up on backends that support
  /// mirroring AND when wl-mirror is installed; otherwise it stays null
  /// and the menu omits the mirror entries entirely.
  final ValueChanged<String?>? onSetMirror;
  /// Other monitors in the same profile that are valid mirror sources
  /// (enabled, not themselves mirrors, and not this tile). Used to populate
  /// the "Mirror onto …" submenu.
  final List<MonitorTileData> mirrorSources;

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
    this.onScaleCommit,
    this.onModeChange,
    this.onToggleEnabled,
    this.onCustomMode,
    this.onCustomModeRevert,
    this.identifyNumber,
    this.onSetMirror,
    this.mirrorSources = const [],
  });

  @override
  State<MonitorTile> createState() => _MonitorTileState();
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
    final isMirror = widget.data.mirrorOf != null;
    // Mirror tiles get a cyan accent so the user can see at a glance that
    // they are subordinate to another output. Drag/scale are also locked
    // for them since their position/size are inherited from the source.
    final backgroundColor = !isEnabled
        ? Colors.grey.withValues(alpha: 0.4)
        : isMirror
            ? const Color(0xFF4FC3F7).withValues(alpha: 0.18)
            : (widget.exists
                ? Colors.green.withValues(alpha: 0.3)
                : Colors.red.withValues(alpha: 0.3));
    final borderColor = !isEnabled
        ? Colors.grey
        : isMirror
            ? const Color(0xFF4FC3F7)
            : (widget.exists ? Colors.greenAccent : Colors.redAccent);
    final textColor = isEnabled ? Colors.white : Colors.white70;
    final canDrag = isEnabled && !isMirror;
    final canResize = canDrag;
    final canChangeMode = canDrag;

    return Positioned(
      left: position.dx,
      top: position.dy,
      width: tileWidth,
      height: tileHeight,
      child: Stack(
        children: [
          GestureDetector(
            onPanStart: canDrag ? (_) => widget.onDragStart?.call() : null,
            onPanUpdate: canDrag
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
            onPanEnd: canDrag ? (_) => widget.onDragEnd() : null,
            onSecondaryTap: canDrag
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
                        if (isMirror)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 4),
                            child: Text(
                              '⇄ Mirror of ${widget.data.mirrorOf}',
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: Color(0xFF4FC3F7),
                              ),
                            ),
                          ),
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
          if (canResize)
            Positioned(
              right: 0,
              bottom: 0,
              child: MouseRegion(
                cursor: SystemMouseCursors.resizeUpLeftDownRight,
                child: GestureDetector(
                  onPanUpdate: (details) {
                    setState(() {
                      tileWidth += details.delta.dx;
                      tileHeight += details.delta.dy;
                      if (tileWidth < 20) tileWidth = 20;
                      if (tileHeight < 20) tileHeight = 20;
                    });
                    // Live update only — no snapping during the drag so
                    // the user never feels glued to integer scales.
                    final newScale = double.parse((widget.originalWidth /
                            ((tileWidth) / widget.scaleFactor))
                        .toStringAsFixed(2));
                    widget.onScale?.call(newScale);
                  },
                  onPanEnd: (_) {
                    // Final commit — controller decides whether to
                    // raster onto a snap value.
                    final finalScale = double.parse((widget.originalWidth /
                            ((tileWidth) / widget.scaleFactor))
                        .toStringAsFixed(2));
                    widget.onScaleCommit?.call(finalScale);
                  },
                  child: Container(
                    width: 16,
                    height: 16,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.5),
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
                            ? 'Disable display'
                            : 'Enable display',
                      ),
                    ),
                  if (widget.onSetMirror != null && isMirror)
                    MenuItemButton(
                      onPressed: () => widget.onSetMirror!.call(null),
                      leadingIcon: const Icon(Icons.link_off, size: 18),
                      child: const Text('Stop mirroring'),
                    ),
                  if (widget.onSetMirror != null &&
                      !isMirror &&
                      widget.mirrorSources.isNotEmpty)
                    SubmenuButton(
                      leadingIcon:
                          const Icon(Icons.compare_arrows, size: 18),
                      menuChildren: [
                        for (final src in widget.mirrorSources)
                          MenuItemButton(
                            onPressed: () =>
                                widget.onSetMirror!.call(src.id),
                            child: Text(
                              src.manufacturer.isNotEmpty
                                  ? '${src.id} (${src.manufacturer})'
                                  : src.id,
                            ),
                          ),
                      ],
                      child: const Text('Mirror onto…'),
                    ),
                  if (canChangeMode && widget.data.modes.isNotEmpty)
                    SubmenuButton(
                      menuChildren: _buildModeMenuItems(),
                      child: const Text('Resolution / Hz'),
                    ),
                  if (canChangeMode &&
                      (widget.onCustomMode != null ||
                          widget.onCustomModeRevert != null))
                    SubmenuButton(
                      menuChildren: [
                        if (widget.onCustomMode != null)
                          MenuItemButton(
                            onPressed: widget.onCustomMode,
                            child: const Text('Custom Mode...'),
                          ),
                        if (widget.onCustomModeRevert != null)
                          MenuItemButton(
                            onPressed: widget.onCustomModeRevert,
                            child: const Text('Revert last custom mode'),
                          ),
                      ],
                      child: const Text('Advanced'),
                    ),
                ],
              ),
            ),
          if (widget.identifyNumber != null)
            Positioned.fill(
              child: IdentifyOverlay(number: widget.identifyNumber!),
            ),
        ],
      ),
    );
  }

  List<Widget> _buildModeMenuItems() {
    // Gruppiere nach Auflösung, sortiere absteigend nach Fläche, dann Hz.
    final grouped = groupBy<MonitorMode, String>(
      widget.data.modes,
      (m) => '${m.width.toInt()}x${m.height.toInt()}',
    );

    List<String> keys = grouped.keys.toList()
      ..sort((a, b) {
        final partsA = a.split('x').map(int.parse).toList();
        final partsB = b.split('x').map(int.parse).toList();
        final areaA = partsA[0] * partsA[1];
        final areaB = partsB[0] * partsB[1];
        if (areaA != areaB) return areaB.compareTo(areaA); // absteigend Fläche
        return b.compareTo(a);
      });

    List<Widget> items = [];
    for (final res in keys) {
      final modesForRes = [...grouped[res] ?? []]
        ..sort((a, b) => b.refresh.compareTo(a.refresh)); // Hz absteigend
      final best = modesForRes.first;

      items.add(
        MenuAnchor(
          menuChildren: [
            for (final m in modesForRes)
              MenuItemButton(
                onPressed: widget.onModeChange != null && widget.data.enabled
                    ? () => widget.onModeChange!(m)
                    : null,
                child: Text(m.label),
              ),
          ],
          builder: (context, controller, child) {
            return Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Expanded(
                  child: TextButton(
                    onPressed: widget.onModeChange != null &&
                            widget.data.enabled
                        ? () => widget.onModeChange!(best)
                        : null,
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(res),
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.chevron_right, size: 16),
                  onPressed: () {
                    if (controller.isOpen) {
                      controller.close();
                    } else {
                      controller.open();
                    }
                  },
                ),
              ],
            );
          },
        ),
      );
    }
    return items;
  }
}
