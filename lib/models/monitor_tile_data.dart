// lib/models/monitor_tile_data.dart

class MonitorTileData {
  final String id;
  final double x;       // absolute top-left in “virtual coordinates”
  final double y;       // absolute top-left in “virtual coordinates”
  final double width;   // “absolute” width (typischerweise aus realer Auflösung abgeleitet)
  final double height;  // “absolute” Höhe
  final int rotation;   // 0, 90, 180, 270
  final String resolution;
  final String orientation; // "landscape" oder "portrait"

  MonitorTileData({
    required this.id,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    required this.rotation,
    required this.resolution,
    required this.orientation,
  });

  MonitorTileData copyWith({
    String? id,
    double? x,
    double? y,
    double? width,
    double? height,
    int? rotation,
    String? resolution,
    String? orientation,
  }) {
    return MonitorTileData(
      id: id ?? this.id,
      x: x ?? this.x,
      y: y ?? this.y,
      width: width ?? this.width,
      height: height ?? this.height,
      rotation: rotation ?? this.rotation,
      resolution: resolution ?? this.resolution,
      orientation: orientation ?? this.orientation,
    );
  }
}