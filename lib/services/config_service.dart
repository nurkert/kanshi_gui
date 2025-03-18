// lib/services/config_service.dart

import 'dart:io';
import 'dart:async';

import 'package:kanshi_gui/models/monitor_tile_data.dart';
import 'package:kanshi_gui/models/profiles.dart';

class ConfigService {
  // Pfad zur kanshi Config (bitte ggf. anpassen)
  final String configPath = '/home/nburkert/.config/kanshi/config';

  /// Liest die Config-Datei ein, parst sie in Profile-Objekte.
  Future<List<Profile>> loadProfiles() async {
    final file = File(configPath);
    if (await file.exists()) {
      final content = await file.readAsString();
      List<Profile> profiles = [];

      // Profile-Blöcke finden: profile 'name' { ... }
      RegExp profileBlockRegExp = RegExp(
        r"profile\s+'([^']+)'\s*\{([^}]*)\}",
        dotAll: true,
      );
      Iterable<RegExpMatch> profileMatches = profileBlockRegExp.allMatches(content);

      for (final match in profileMatches) {
        String profileName = match.group(1)!.trim();
        String blockContent = match.group(2)!;

        List<MonitorTileData> monitors = [];

        // This regex now optionally parses a size after the position:
        RegExp outputLineRegExp = RegExp(
          r"output\s+'([^']+)'\s+(enable|disable)(?:\s+scale\s+(\S+))?\s+transform\s+(\S+)\s+position\s+(-?\d+),(-?\d+)(?:\s+size\s+(\d+),(\d+))?",
        );
        Iterable<RegExpMatch> outputMatches = outputLineRegExp.allMatches(blockContent);

        for (final outputMatch in outputMatches) {
          String monitorId = outputMatch.group(1)!.trim();
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

          // Try to parse the size if present
          double width;
          double height;
          if (outputMatch.group(7) != null && outputMatch.group(8) != null) {
            width = double.tryParse(outputMatch.group(7)!) ?? 1920;
            height = double.tryParse(outputMatch.group(8)!) ?? 1080;
          } else {
            // Defaults: 1920x1080 bei normal/180, sonst 1080x1920.
            width = (rotation == 90 || rotation == 270) ? 1080 : 1920;
            height = (rotation == 90 || rotation == 270) ? 1920 : 1080;
          }

          double x = double.tryParse(outputMatch.group(5)!) ?? 0;
          double y = double.tryParse(outputMatch.group(6)!) ?? 0;

          String resolution = "${width.toInt()}x${height.toInt()}";
          String orientation = (rotation == 90 || rotation == 270) ? "portrait" : "landscape";

          monitors.add(MonitorTileData(
            id: monitorId,
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

  /// Schreibt alle Profile wieder im kanshi-Format in die Config-Datei.
  Future<void> saveProfiles(List<Profile> profiles) async {
    StringBuffer buffer = StringBuffer();

    for (final profile in profiles) {
      // Adjust negative coordinates if any.
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

      // Sort monitors from left to right.
      adjustedMonitors.sort((a, b) => a.x.compareTo(b.x));

      buffer.writeln("profile '${profile.name}' {");

      int workspace = 1;
      for (final monitor in adjustedMonitors) {
        int posX = (monitor.x < 0) ? 0 : monitor.x.toInt();
        int posY = (monitor.y < 0) ? 0 : monitor.y.toInt();

        String transformStr = (monitor.rotation == 0)
            ? 'normal'
            : monitor.rotation.toString(); // e.g. "90", "180", "270"

        // Save the actual size so that the correct dimensions are loaded later.
        buffer.writeln(
          "    output '${monitor.id}' enable scale 1 transform $transformStr position $posX,$posY size ${monitor.width.toInt()},${monitor.height.toInt()}",
        );
        buffer.writeln(
          "    exec swaymsg \"workspace $workspace output '${monitor.id}'; workspace $workspace\"",
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
