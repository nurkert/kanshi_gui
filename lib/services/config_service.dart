// lib/services/config_service.dart

import 'dart:io';
import 'dart:async';
import 'package:kanshi_gui/models/monitor_tile_data.dart';
import 'package:kanshi_gui/models/profiles.dart';

class ConfigService {
  final String configPath = "${Platform.environment['HOME']}/.config/kanshi/config";
Future<List<Profile>> loadProfiles() async {
  final file = File(configPath);
  if (await file.exists()) {
    final content = await file.readAsString();
    List<Profile> profiles = [];

    // Profil-Blöcke finden: profile 'Name' { ... }
    RegExp profileBlockRegExp = RegExp(
      r"profile\s+'([^']+)'\s*\{([^}]*)\}",
      dotAll: true,
    );
    Iterable<RegExpMatch> profileMatches = profileBlockRegExp.allMatches(content);

    for (final match in profileMatches) {
      String profileName = match.group(1)!.trim();
      String blockContent = match.group(2)!;

      List<MonitorTileData> monitors = [];

      // Regex ohne size-Anteil:
      RegExp outputLineRegExp = RegExp(
        r"output\s+'([^']+)'\s+(enable|disable)(?:\s+scale\s+(\S+))?\s+transform\s+(\S+)\s+position\s+(-?\d+),(-?\d+)",
      );
      Iterable<RegExpMatch> outputMatches = outputLineRegExp.allMatches(blockContent);

      for (final outputMatch in outputMatches) {
        // Gruppe 1: kompletter Herstellerstring (als ID und Anzeige)
        String manufacturer = outputMatch.group(1)!.trim();
        double x = double.tryParse(outputMatch.group(5)!) ?? 0;
        double y = double.tryParse(outputMatch.group(6)!) ?? 0;
        String transform = outputMatch.group(4)!.trim();

        int rotation = 0;
        if (transform == 'normal') {
          rotation = 0;
        } else if (transform == '90') {
          rotation = 90;
        } else if (transform == '180') {
          rotation = 180;
        } else if (transform == '270') {
          rotation = 270;
        }

        // Default-Werte: Für normal/180 nehmen wir 1920x1080, bei 90/270 1080x1920
        double width, height;
        if (rotation == 90 || rotation == 270) {
          width = 1080;
          height = 1920;
        } else {
          width = 1920;
          height = 1080;
        }
        String resolution = "${width.toInt()}x${height.toInt()}";
        String orientation = (rotation == 90 || rotation == 270) ? "portrait" : "landscape";

        monitors.add(MonitorTileData(
          id: manufacturer,
          manufacturer: manufacturer,
          x: x,
          y: y,
          width: width,
          height: height,
          rotation: rotation,
          resolution: resolution,
          orientation: orientation,
        ));
      }
      profiles.add(Profile(name: profileName, monitors: monitors));
    }
    return profiles;
  }
  return [];
}

  
 Future<void> saveProfiles(List<Profile> profiles) async {
  StringBuffer buffer = StringBuffer();

  for (final profile in profiles) {
    // Korrigiere negative Koordinaten:
    double minX = profile.monitors.map((m) => m.x).reduce((a, b) => a < b ? a : b);
    double minY = profile.monitors.map((m) => m.y).reduce((a, b) => a < b ? a : b);
    double offsetX = (minX < 0) ? -minX : 0;
    double offsetY = (minY < 0) ? -minY : 0;

    List<MonitorTileData> adjustedMonitors = profile.monitors.map((m) {
      return m.copyWith(
        x: m.x + offsetX,
        y: m.y + offsetY,
      );
    }).toList();

    // Sortiere Monitore von links nach rechts:
    adjustedMonitors.sort((a, b) => a.x.compareTo(b.x));

    buffer.writeln("profile '${profile.name}' {");

    int workspace = 1;
    for (final monitor in adjustedMonitors) {
      int posX = (monitor.x < 0) ? 0 : monitor.x.toInt();
      int posY = (monitor.y < 0) ? 0 : monitor.y.toInt();

      String transformStr = (monitor.rotation == 0) ? 'normal' : monitor.rotation.toString();

      // Schreibe den kompletten Herstellerstring ohne "size":
      buffer.writeln(
        "    output '${monitor.manufacturer}' enable scale 1 transform $transformStr position $posX,$posY"
      );
      buffer.writeln(
        "    exec swaymsg \"workspace $workspace output '${monitor.manufacturer}'; workspace $workspace\""
      );
      workspace++;
    }
    buffer.writeln("    exec echo \"${profile.name}\" > ~/.current_kanshi_profile");
    buffer.writeln("}\n");
  }

  final file = File(configPath);
  await file.writeAsString(buffer.toString());
}

}
