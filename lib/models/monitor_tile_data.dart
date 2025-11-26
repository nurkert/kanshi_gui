// lib/models/monitor_tile_data.dart

import 'monitor_mode.dart';

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
    );
  }
}
