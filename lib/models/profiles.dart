import 'monitor_tile_data.dart';

/// Represents a display profile containing monitor configurations.
class Profile {
  String name;
  List<MonitorTileData> monitors;

  Profile({required this.name, required this.monitors});
}
