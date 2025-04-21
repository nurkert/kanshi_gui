import 'dart:async';
import 'dart:io';

import 'package:kanshi_gui/models/monitor_tile_data.dart';
import 'package:kanshi_gui/models/profiles.dart';

class ConfigService {
  final String configPath =
      "${Platform.environment['HOME']}/.config/kanshi/config";

  /*───────────────────────────────*
   *  LOAD                          *
   *───────────────────────────────*/
  Future<List<Profile>> loadProfiles() async {
    final file = File(configPath);
    if (!await file.exists()) return [];

    final content = await file.readAsString();
    final profiles = <Profile>[];

    final profileRE =
        RegExp(r"profile\s+'([^']+)'\s*\{([^}]*)\}", dotAll: true);

    for (final match in profileRE.allMatches(content)) {
      final name = match.group(1)!.trim();
      final body = match.group(2)!;

      final outputs = <MonitorTileData>[];

      // ── ohne "mode" ──
      final outputRE = RegExp(
        r"output\s+'([^']+)'\s+(enable|disable)"
        r"(?:\s+scale\s+(\S+))?"
        r"\s+transform\s+(\S+)\s+position\s+(-?\d+),(-?\d+)",
      );

      for (final o in outputRE.allMatches(body)) {
        final fullName = o.group(1)!.trim();
        final rotationStr = o.group(4)!.trim();
        final x = double.parse(o.group(5)!);
        final y = double.parse(o.group(6)!);

        final rotation = switch (rotationStr) {
          '90' => 90,
          '180' => 180,
          '270' => 270,
          _ => 0,
        };

        // Fallback‑Größen (wie ursprünglich)
        final landscape = rotation % 180 == 0;
        final width = landscape ? 1920.0 : 1080.0;
        final height = landscape ? 1080.0 : 1920.0;

        final resolution = "${width.toInt()}x${height.toInt()}";
        final orientation =
            (rotation % 180 == 0) ? "landscape" : "portrait";

        outputs.add(
          MonitorTileData(
            id: fullName,
            manufacturer: fullName,
            x: x,
            y: y,
            width: width,
            height: height,
            rotation: rotation,
            resolution: resolution,
            orientation: orientation,
          ),
        );
      }

      profiles.add(Profile(name: name, monitors: outputs));
    }

    return profiles;
  }

  /*───────────────────────────────*
   *  SAVE                          *
   *───────────────────────────────*/
  Future<void> saveProfiles(List<Profile> profiles) async {
    final buffer = StringBuffer();

    for (final profile in profiles) {
      // Negative Koordinaten eliminieren
      final minX =
          profile.monitors.map((m) => m.x).reduce((a, b) => a < b ? a : b);
      final minY =
          profile.monitors.map((m) => m.y).reduce((a, b) => a < b ? a : b);
      final offsetX = minX < 0 ? -minX : 0;
      final offsetY = minY < 0 ? -minY : 0;

      final mons = profile.monitors
          .map((m) => m.copyWith(x: m.x + offsetX, y: m.y + offsetY))
          .toList()
        ..sort((a, b) => a.x.compareTo(b.x));

      buffer.writeln("profile '${profile.name}' {");

      /*── 1. Outputs ───────────────────────────────────────────*/
      for (final m in mons) {
        final posX = m.x < 0 ? 0 : m.x.toInt();
        final posY = m.y < 0 ? 0 : m.y.toInt();
        final transform = m.rotation == 0 ? 'normal' : m.rotation.toString();

        buffer.writeln(
          "    output '${m.id}' enable scale 1 transform $transform position $posX,$posY",
        );
      }

      /*── 2. Workspace‑Moves ──────────────────────────────────*
       *    Zuerst hohe Nummern → dann Zielnummern              */
      final tmpBase = mons.length + 1; // z. B. 4 … 6 bei 3 Monitoren

      for (var i = 0; i < mons.length; i++) {
        final m = mons[i];
        final tmpWS = tmpBase + i;
        buffer.writeln(
          "    exec swaymsg \"workspace $tmpWS output '${m.manufacturer}'; workspace $tmpWS\"",
        );
      }
      for (var i = 0; i < mons.length; i++) {
        final m = mons[i];
        final finalWS = i + 1;
        buffer.writeln(
          "    exec swaymsg \"workspace $finalWS output '${m.manufacturer}'; workspace $finalWS\"",
        );
      }

      buffer.writeln(
        "    exec echo \"${profile.name}\" > ~/.current_kanshi_profile",
      );
      buffer.writeln("}\n");
    }

    final file = File(configPath);
    await file.create(recursive: true);
    await file.writeAsString(buffer.toString());
  }
}
