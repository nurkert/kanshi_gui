// lib/models/monitor_tile_data.dart

import 'monitor_mode.dart';

/// One monitor tile in a profile.
///
/// **Coordinate spaces** — the snap engine, the layout writer and the
/// Sway IPC apply path all assume the same convention; do not mix them:
///
/// - [x] / [y] are **logical** (post-scale) layout coordinates. They live
///   in the same global Wayland layout space Sway exposes via its
///   `output … position X Y` IPC, so a 4K display at scale 2.0 placed
///   flush to the right of a 1080p panel sits at `x = 1920` (the logical
///   extent of the 1080p neighbour), not `x = 3840`.
/// - [width] / [height] are **physical** pixels — the raw mode dimensions
///   of the panel. The kanshi config and `swaymsg output mode` both want
///   the physical mode here. To get the logical extent at a given scale
///   use `width / scale`, which is what the snap math, the bounding box
///   helper and the destination filter all do.
/// - [scale] is the per-output HiDPI scale factor (1.0 = 1×, 2.0 = 2×).
class MonitorTileData {
  final String id;
  final String manufacturer; // Neuer Herstellerstring
  final double x;
  final double y;
  final double width;
  final double height;
  final double scale;
  final int rotation;
  final double refresh;
  final String resolution;
  final String orientation;
  final List<MonitorMode> modes;
  final bool enabled;
  /// When non-null, this monitor mirrors the output named here (Sway's
  /// `output X mirror Y` IPC). The compositor inherits mode / position /
  /// scale / transform from the target, so this monitor's own
  /// position/mode fields are advisory only while the mirror is active.
  final String? mirrorOf;
  /// Optional 0-indexed left-to-right rank that overrides the X-position
  /// derived rank used by the Sway workspace-distribution pass. `null`
  /// means "derive from X". Persisted in the kanshi config as a
  /// `# kanshi_gui:rank '<id>'=<n>` comment so the override survives an
  /// app restart and external `kanshictl reload` invocations.
  final int? workspaceRank;

  MonitorTileData({
    required this.id,
    required this.manufacturer,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    this.scale = 1.0,
    required this.rotation,
    required this.refresh,
    required this.resolution,
    required this.orientation,
    this.modes = const [],
    this.enabled = true,
    this.mirrorOf,
    this.workspaceRank,
  });

  MonitorTileData copyWith({
    String? id,
    String? manufacturer,
    double? x,
    double? y,
    double? width,
    double? height,
    double? scale,
    int? rotation,
    double? refresh,
    String? resolution,
    String? orientation,
    List<MonitorMode>? modes,
    bool? enabled,
    Object? mirrorOf = _sentinel,
    Object? workspaceRank = _sentinel,
  }) {
    return MonitorTileData(
      id: id ?? this.id,
      manufacturer: manufacturer ?? this.manufacturer,
      x: x ?? this.x,
      y: y ?? this.y,
      width: width ?? this.width,
      height: height ?? this.height,
      scale: scale ?? this.scale,
      rotation: rotation ?? this.rotation,
      refresh: refresh ?? this.refresh,
      resolution: resolution ?? this.resolution,
      orientation: orientation ?? this.orientation,
      modes: modes ?? this.modes,
      enabled: enabled ?? this.enabled,
      // `mirrorOf` is nullable in the model, so `null` is a meaningful
      // value (release the mirror). The sentinel lets copyWith distinguish
      // "explicitly clear to null" from "leave unchanged".
      mirrorOf: identical(mirrorOf, _sentinel)
          ? this.mirrorOf
          : mirrorOf as String?,
      workspaceRank: identical(workspaceRank, _sentinel)
          ? this.workspaceRank
          : workspaceRank as int?,
    );
  }
}

const Object _sentinel = Object();
