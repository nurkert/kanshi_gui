import 'dart:async';
import 'dart:io';

import 'package:kanshi_gui/models/monitor_tile_data.dart';
import 'package:kanshi_gui/models/profiles.dart';

class ConfigService {
  /// Standardpfad: ~/.config/kanshi/config
  final String configPath =
      "${Platform.environment['HOME']}/.config/kanshi/config";

  /*───────────────────────────────────────────*
   *  LOAD PROFILES                            *
   *───────────────────────────────────────────*/
  Future<List<Profile>> loadProfiles() async {
    final file = File(configPath);
    if (!await file.exists()) return [];

    final content = await file.readAsString();
    final profiles = <Profile>[];

    // profile 'Name' { … }
    final profileBlockRE =
        RegExp(r"profile\s+'([^']+)'\s*\{([^}]*)\}", dotAll: true);

    for (final profMatch in profileBlockRE.allMatches(content)) {
      final profileName = profMatch.group(1)!.trim();
      final block = profMatch.group(2)!;

      final outputs = <MonitorTileData>[];

      /*
       * output '<FULL NAME>' enable scale 1
       *        mode <W>x<H>[@Hz] transform <rot> position X,Y
       */
      final outputRE = RegExp(
        r"output\s+'([^']+)'\s+enable"           // 1: Voller Name
        r"(?:\s+scale\s+([\d.]+))?"             // 2: scale optional
        r"\s+mode\s+(\d+)x(\d+)(?:@\S+)?\s+"    // 3: W, 4: H, Hz ignorieren
        r"transform\s+(\S+)\s+"                 // 5: transform
        r"position\s+(-?\d+),(-?\d+)",           // 6: X, 7: Y
      );

      for (final outMatch in outputRE.allMatches(block)) {
        final fullName = outMatch.group(1)!.trim();
        final scaleStr = outMatch.group(2);
        final modeW = double.parse(outMatch.group(3)!);
        final modeH = double.parse(outMatch.group(4)!);
        final transform = outMatch.group(5)!.trim();
        final posX = double.parse(outMatch.group(6)!);
        final posY = double.parse(outMatch.group(7)!);
        final scale = scaleStr != null ? double.parse(scaleStr) : 1.0;

        final rotation = switch (transform) {
          '90' => 90,
          '180' => 180,
          '270' => 270,
          _ => 0,
        };

        // Breite/Höhe abhängig von Rotation drehen
        final width  = (rotation % 180 == 0) ? modeW : modeH;
        final height = (rotation % 180 == 0) ? modeH : modeW;

        final resolution = "${width.toInt()}x${height.toInt()}";
        final orientation =
            (rotation % 180 == 0) ? "landscape" : "portrait";

        outputs.add(
          MonitorTileData(
            id: fullName,
            manufacturer: fullName,
            x: posX,
            y: posY,
            width: width,
            height: height,
            scale: scale,
            rotation: rotation,
            resolution: resolution,
            orientation: orientation,
          ),
        );
      }

      profiles.add(Profile(name: profileName, monitors: outputs));
    }
    return profiles;
  }

  /*───────────────────────────────────────────*
   *  SAVE PROFILES                            *
   *───────────────────────────────────────────*/
  Future<void> saveProfiles(List<Profile> profiles) async {
    final buffer = StringBuffer();

    for (final profile in profiles) {
      // Negative Koordinaten zu Null klappen
      final minX =
          profile.monitors.map((m) => m.x).reduce((a, b) => a < b ? a : b);
      final minY =
          profile.monitors.map((m) => m.y).reduce((a, b) => a < b ? a : b);
      final offsetX = (minX < 0) ? -minX : 0;
      final offsetY = (minY < 0) ? -minY : 0;

      final mons = profile.monitors
          .map((m) => m.copyWith(x: m.x + offsetX, y: m.y + offsetY))
          .toList()
        ..sort((a, b) => a.x.compareTo(b.x));

      buffer.writeln("profile '${profile.name}' {");

      /*── 1. Outputs ──────────────────────────────────────────*/
      for (final m in mons) {
        // Breite/Höhe immer landscape‑orientiert in mode‑Zeile
        final baseW = (m.rotation % 180 == 0) ? m.width : m.height;
        final baseH = (m.rotation % 180 == 0) ? m.height : m.width;

        final posX = m.x < 0 ? 0 : m.x.toInt();
        final posY = m.y < 0 ? 0 : m.y.toInt();
        final transform = m.rotation == 0 ? 'normal' : m.rotation.toString();

        buffer.writeln(
          "    output '${m.id}' enable scale ${m.scale} "
          "mode ${baseW.toInt()}x${baseH.toInt()} "
          "transform $transform position $posX,$posY",
        );
      }

      /*── 2. Workspace‑Moves (erst hoch, dann final) ─────────*/
      final tmpBase = mons.length + 1; // z. B. 4–6 bei 3 Monitoren
      for (var i = 0; i < mons.length; i++) {
        final m = mons[i];
        buffer.writeln(
          "    exec swaymsg \"workspace ${tmpBase + i} output '${m.manufacturer}'; workspace ${tmpBase + i}\"",
        );
      }
      for (var i = 0; i < mons.length; i++) {
        final m = mons[i];
        buffer.writeln(
          "    exec swaymsg \"workspace ${i + 1} output '${m.manufacturer}'; workspace ${i + 1}\"",
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
