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
  /// Output ids that mirror *this* tile. When non-empty the tile renders
  /// with the cyan mirror accent and a "→ Mirrors to A, B" label, and the
  /// three-dot menu gains a "Stop mirroring X" entry per destination so
  /// the relationship can be released without reaching for the now-hidden
  /// destination tile.
  final List<String> mirroredBy;
  /// Used by the "Stop mirroring X" menu items: the parent clears the
  /// mirror by calling `onSetMirror?.call(null)` on the *destination*
  /// tile, but here we are the source — so we need a callback that names
  /// the destination explicitly.
  final void Function(String destId)? onStopMirroredBy;
  /// Number of enabled outputs in the active profile. Determines the
  /// number of choices in the "Workspace position" submenu (1..N).
  /// 0 means the menu entry is hidden.
  final int workspacePositionCount;
  /// 0-indexed effective rank of this monitor in the active profile's
  /// workspace distribution (i.e. the rank actually used by the writer
  /// after collision resolution). Highlights the current entry in the
  /// submenu and is the value reported when no override is set.
  final int? workspacePositionEffective;
  /// True when the user has set an explicit override for this monitor —
  /// shown in the menu so they know it differs from the auto-derived
  /// rank, and lets them clear the override via "Auto (left-to-right)".
  final bool workspacePositionExplicit;
  /// Pass the new 0-indexed rank or `null` to clear the override.
  final void Function(int? rank)? onSetWorkspaceRank;
  /// Reads the controller's current drag-cancel epoch. The tile snapshots
  /// the value in `onPanStart` and treats any later update whose epoch
  /// differs as cancelled (hotplug / profile-switch invalidated the
  /// drag). Cancelled drags snap back to their pre-drag position
  /// silently.
  final int Function()? readDragCancelEpoch;
  /// Identify-numbers of the destinations that mirror this tile, in the
  /// same order as [mirroredBy]. When identify is active the source tile
  /// renders these as small cyan chips next to its own big number, so
  /// the user can see at a glance which physical screens carry the
  /// same content.
  final List<int> mirroredByNumbers;

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
    this.mirroredBy = const [],
    this.onStopMirroredBy,
    this.workspacePositionCount = 0,
    this.workspacePositionEffective,
    this.workspacePositionExplicit = false,
    this.onSetWorkspaceRank,
    this.readDragCancelEpoch,
    this.mirroredByNumbers = const [],
  });

  @override
  State<MonitorTile> createState() => _MonitorTileState();
}

class _MonitorTileState extends State<MonitorTile> {
  late Offset position; // Position innerhalb der Stack (skaliert)
  late double tileWidth;
  late double tileHeight;
  /// Cancel-epoch sampled at drag start. If the controller's epoch
  /// advances mid-drag (hotplug / profile switch), the gesture is
  /// invalidated and we snap back to [_dragOrigin].
  int? _sessionEpoch;
  /// The tile's `position` at drag start, used to roll back on cancel.
  Offset? _dragOrigin;

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
    // A tile is "mirror-styled" when it acts as a mirror source — its
    // pixels are duplicated onto one or more destination outputs. The
    // destination tiles themselves are filtered out by LayoutMath, so
    // [data.mirrorOf] should never be true here in normal flow; we still
    // guard against it for defensive rendering.
    final isMirrorSource = widget.mirroredBy.isNotEmpty;
    final isMirrorDestination = widget.data.mirrorOf != null;
    final hasMirrorAccent = isMirrorSource || isMirrorDestination;
    final backgroundColor = !isEnabled
        ? Colors.grey.withValues(alpha: 0.4)
        : hasMirrorAccent
            ? const Color(0xFF4FC3F7).withValues(alpha: 0.18)
            : (widget.exists
                ? Colors.green.withValues(alpha: 0.3)
                : Colors.red.withValues(alpha: 0.3));
    final borderColor = !isEnabled
        ? Colors.grey
        : hasMirrorAccent
            ? const Color(0xFF4FC3F7)
            : (widget.exists ? Colors.greenAccent : Colors.redAccent);
    final textColor = isEnabled ? Colors.white : Colors.white70;
    final canDrag = isEnabled && !isMirrorDestination;
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
            onPanStart: canDrag
                ? (_) {
                    _sessionEpoch = widget.readDragCancelEpoch?.call();
                    _dragOrigin = position;
                    widget.onDragStart?.call();
                  }
                : null,
            onPanUpdate: canDrag
                ? (details) {
                    if (_isDragCancelled()) {
                      _abortDrag();
                      return;
                    }
                    setState(() => position += details.delta);
                    widget.onUpdate(
                      widget.data.copyWith(
                        x: position.dx,
                        y: position.dy,
                      ),
                    );
                  }
                : null,
            onPanEnd: canDrag
                ? (_) {
                    if (_isDragCancelled()) {
                      _abortDrag();
                      return;
                    }
                    _sessionEpoch = null;
                    _dragOrigin = null;
                    widget.onDragEnd();
                  }
                : null,
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
                        if (isMirrorSource)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 4),
                            child: Text(
                              '⇄ Mirrors to ${widget.mirroredBy.join(", ")}',
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: Color(0xFF4FC3F7),
                              ),
                            ),
                          )
                        else if (isMirrorDestination)
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
                  if (widget.onSetMirror != null && isMirrorDestination)
                    MenuItemButton(
                      onPressed: () => widget.onSetMirror!.call(null),
                      leadingIcon: const Icon(Icons.link_off, size: 18),
                      child: const Text('Stop mirroring'),
                    ),
                  if (widget.onStopMirroredBy != null && isMirrorSource)
                    for (final dst in widget.mirroredBy)
                      MenuItemButton(
                        onPressed: () =>
                            widget.onStopMirroredBy!.call(dst),
                        leadingIcon: const Icon(Icons.link_off, size: 18),
                        child: Text('Stop mirroring to $dst'),
                      ),
                  if (widget.onSetMirror != null &&
                      !isMirrorDestination &&
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
                  if (widget.onSetWorkspaceRank != null &&
                      widget.workspacePositionCount > 1 &&
                      widget.data.enabled &&
                      !isMirrorDestination)
                    SubmenuButton(
                      leadingIcon: const Icon(Icons.tag, size: 18),
                      menuChildren: [
                        MenuItemButton(
                          onPressed: () =>
                              widget.onSetWorkspaceRank!.call(null),
                          leadingIcon: Icon(
                            widget.workspacePositionExplicit
                                ? Icons.auto_awesome
                                : Icons.check,
                            size: 18,
                          ),
                          child: const Text('Auto (left-to-right)'),
                        ),
                        for (var i = 0;
                            i < widget.workspacePositionCount;
                            i++)
                          MenuItemButton(
                            onPressed: () =>
                                widget.onSetWorkspaceRank!.call(i),
                            leadingIcon: Icon(
                              widget.workspacePositionEffective == i &&
                                      widget.workspacePositionExplicit
                                  ? Icons.check
                                  : Icons.tag,
                              size: 18,
                            ),
                            child: Text('Position ${i + 1}'),
                          ),
                      ],
                      child: Text(
                        widget.workspacePositionEffective == null
                            ? 'Workspace position'
                            : 'Workspace position '
                                '(${widget.workspacePositionEffective! + 1}'
                                '${widget.workspacePositionExplicit ? '' : ' auto'})',
                      ),
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
          if (widget.identifyNumber != null &&
              widget.mirroredByNumbers.isNotEmpty)
            Positioned(
              right: 6,
              top: 6,
              child: Wrap(
                spacing: 4,
                children: [
                  for (final n in widget.mirroredByNumbers)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFF4FC3F7).withValues(alpha: 0.85),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        '+$n',
                        style: const TextStyle(
                          color: Colors.black,
                          fontWeight: FontWeight.bold,
                          fontSize: 12,
                        ),
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  bool _isDragCancelled() {
    final epoch = _sessionEpoch;
    if (epoch == null) return false;
    final current = widget.readDragCancelEpoch?.call();
    return current != null && current != epoch;
  }

  void _abortDrag() {
    final origin = _dragOrigin;
    if (origin != null && mounted) {
      setState(() => position = origin);
    }
    _sessionEpoch = null;
    _dragOrigin = null;
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
