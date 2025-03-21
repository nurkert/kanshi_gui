// lib/models/monitor_tile_data.dart

class MonitorTileData {
  final String id;
  final String manufacturer; // Neuer Herstellerstring
  final double x;       
  final double y;       
  final double width;   
  final double height;  
  final int rotation;   
  final String resolution;
  final String orientation; 

  MonitorTileData({
    required this.id,
    required this.manufacturer,
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
    String? manufacturer,
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
      manufacturer: manufacturer ?? this.manufacturer,
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
