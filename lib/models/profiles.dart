// lib/models/profiles.dart

import 'monitor_tile_data.dart';

class Profile {
  String name;
  List<MonitorTileData> monitors;

  Profile({required this.name, required this.monitors});
}
