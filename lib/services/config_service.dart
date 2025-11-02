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
        r"output\s+'([^']+)'\s+(enable|disable)([^\n]*)",
        caseSensitive: false,
      );

      for (final outMatch in outputRE.allMatches(block)) {
        final fullName = outMatch.group(1)!.trim();
        final state = outMatch.group(2)!.toLowerCase();
        final rest = outMatch.group(3) ?? '';
        final isEnabled = state == 'enable';

        final scaleMatch = RegExp(r"scale\s+([\d.]+)").firstMatch(rest);
        final modeMatch = RegExp(r"mode\s+(\d+)x(\d+)(?:@\S+)?").firstMatch(rest);
        final transformMatch = RegExp(r"transform\s+(\S+)").firstMatch(rest);
        final positionMatch = RegExp(r"position\s+(-?\d+),(-?\d+)").firstMatch(rest);

        final scale =
            scaleMatch != null ? double.parse(scaleMatch.group(1)!) : 1.0;

        final baseW =
            modeMatch != null ? double.parse(modeMatch.group(1)!) : 1920.0;
        final baseH =
            modeMatch != null ? double.parse(modeMatch.group(2)!) : 1080.0;

        final transform = transformMatch?.group(1)?.trim() ?? 'normal';
        final rotation = switch (transform) {
          '90' => 90,
          '180' => 180,
          '270' => 270,
          'flipped-90' => 90,
          'flipped-180' => 180,
          'flipped-270' => 270,
          _ => 0,
        };

        final width = (rotation % 180 == 0) ? baseW : baseH;
        final height = (rotation % 180 == 0) ? baseH : baseW;

        final resolution = "${width.toInt()}x${height.toInt()}";
        final orientation =
            (rotation % 180 == 0) ? "landscape" : "portrait";

        final posX =
            positionMatch != null ? double.parse(positionMatch.group(1)!) : 0.0;
        final posY =
            positionMatch != null ? double.parse(positionMatch.group(2)!) : 0.0;

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
            modes: const [],
            enabled: isEnabled,
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
      if (profile.monitors.isEmpty) continue;
      final referenceMonitors =
          profile.monitors.where((m) => m.enabled).toList();
      final baseForOffsets =
          referenceMonitors.isNotEmpty ? referenceMonitors : profile.monitors;

      // Negative Koordinaten zu Null klappen
      final minX =
          baseForOffsets.map((m) => m.x).reduce((a, b) => a < b ? a : b);
      final minY =
          baseForOffsets.map((m) => m.y).reduce((a, b) => a < b ? a : b);
      final offsetX = (minX < 0) ? -minX : 0;
      final offsetY = (minY < 0) ? -minY : 0;

      final mons = profile.monitors
          .map((m) => m.copyWith(
                x: m.x + offsetX,
                y: m.y + offsetY,
              ))
          .toList()
        ..sort((a, b) => a.x.compareTo(b.x));

      buffer.writeln("profile '${profile.name}' {");

      /*── 1. Outputs ──────────────────────────────────────────*/
      for (final m in mons) {
        if (!m.enabled) {
          buffer.writeln("    output '${m.id}' disable");
          continue;
        }

        // Breite/Höhe immer landscape‑orientiert in mode‑Zeile
        final baseW = (m.rotation % 180 == 0) ? m.width : m.height;
        final baseH = (m.rotation % 180 == 0) ? m.height : m.width;

        final posX = m.x < 0 ? 0 : m.x.toInt();
        final posY = m.y < 0 ? 0 : m.y.toInt();
        final transform = m.rotation == 0 ? 'normal' : m.rotation.toString();

        buffer.writeln(
          "    output '${m.id}' enable scale ${m.scale.toStringAsFixed(2)} "
          "mode ${baseW.toInt()}x${baseH.toInt()} "
          "transform $transform position $posX,$posY",
        );
      }

      /*── 2. Workspace‑Moves (erst hoch, dann final) ─────────*/
      final enabledMons = mons.where((m) => m.enabled).toList();
      final tmpBase = enabledMons.length + 1; // z. B. 4–6 bei 3 Monitoren
      for (var i = 0; i < enabledMons.length; i++) {
        final m = enabledMons[i];
        buffer.writeln(
          "    exec swaymsg \"workspace ${tmpBase + i} output '${m.manufacturer}'; workspace ${tmpBase + i}\"",
        );
      }
      for (var i = 0; i < enabledMons.length; i++) {
        final m = enabledMons[i];
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
