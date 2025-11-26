import 'dart:async';
import 'dart:io';

import 'package:kanshi_gui/models/monitor_tile_data.dart';
import 'package:kanshi_gui/models/monitor_mode.dart';
import 'package:kanshi_gui/models/profiles.dart';

class ConfigService {
  /// Standardpfad: ~/.config/kanshi/config
  final String configPath =
      "${Platform.environment['HOME']}/.config/kanshi/config";
  final String backupPath =
      "${Platform.environment['HOME']}/.config/kanshi/config.bak";

  /// Kleine Helferfunktion: wähle einen gültigen Mode aus der bekannten Liste,
  /// der dem gewünschten (width/height/refresh) am nächsten kommt.
  MonitorMode _pickBestMode(
    MonitorTileData monitor,
    List<MonitorMode> modes,
  ) {
    if (modes.isEmpty) {
      // Fallback: nutze den aktuellen Monitorstate; Refresh notfalls 60.
      return MonitorMode(
        width: monitor.width,
        height: monitor.height,
        refresh: monitor.refresh > 0 ? monitor.refresh : 60,
      );
    }

    // Zielbreite/höhe abhängig von Rotation ermitteln (Mode ist unrotiert)
    final desiredWidth =
        (monitor.rotation % 180 == 0) ? monitor.width : monitor.height;
    final desiredHeight =
        (monitor.rotation % 180 == 0) ? monitor.height : monitor.width;
    final desiredRefresh = monitor.refresh;

    MonitorMode best = modes.first;
    double bestScore = 1e12;

    for (final m in modes) {
      final dw = (m.width - desiredWidth).abs().round();
      final dh = (m.height - desiredHeight).abs().round();
      final dr = (m.refresh - desiredRefresh).abs();
      final score = dw * 2000 + dh * 2000 + dr * 10;
      if (score < bestScore) {
        bestScore = score;
        best = m;
      }
      // Exakter Match bevorzugen
      if (dw == 0 && dh == 0 && dr < 0.01) {
        best = m;
        break;
      }
    }
    return best;
  }

  String _formatHz(double hz) {
    final isInt = (hz - hz.round()).abs() < 0.01;
    return isInt ? hz.round().toString() : hz.toStringAsFixed(3);
  }

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
        final modeMatch =
            RegExp(r"mode\s+(\d+)x(\d+)(?:@(\d+(?:\.\d+)?))?").firstMatch(rest);
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
        final refresh = modeMatch != null
            ? (double.tryParse(modeMatch.group(3) ?? '') ?? 60.0)
            : 60.0;

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
            refresh: refresh,
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
      final offsetX = (minX < 0) ? -minX : 0.0;
      final offsetY = (minY < 0) ? -minY : 0.0;

      final mons = profile.monitors
          .map((m) => _sanitizeMonitor(m, offsetX, offsetY))
          .toList()
        ..sort((a, b) {
          final byX = a.x.compareTo(b.x);
          if (byX != 0) return byX;
          return a.id.compareTo(b.id);
        });

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
    final refresh = m.refresh > 0 ? m.refresh : 60.0;

        final posX = m.x < 0 ? 0 : m.x.toInt();
        final posY = m.y < 0 ? 0 : m.y.toInt();
        final transform = m.rotation == 0 ? 'normal' : m.rotation.toString();

        buffer.writeln(
          "    output '${m.id}' enable scale ${m.scale.toStringAsFixed(2)} "
          "mode ${baseW.toInt()}x${baseH.toInt()}@${_formatHz(refresh)}Hz "
          "transform $transform position $posX,$posY",
        );
      }

      /*── 2. Workspace‑Moves (erst hoch, dann final) ─────────*/
      final enabledMons = mons.where((m) => m.enabled).toList();
      final tmpBase = enabledMons.length + 1; // z. B. 4–6 bei 3 Monitoren
      for (var i = 0; i < enabledMons.length; i++) {
        final m = enabledMons[i];
        buffer.writeln(
          "    exec swaymsg \"workspace ${tmpBase + i} output '${m.id}'; workspace ${tmpBase + i}\"",
        );
      }
      for (var i = 0; i < enabledMons.length; i++) {
        final m = enabledMons[i];
        buffer.writeln(
          "    exec swaymsg \"workspace ${i + 1} output '${m.id}'; workspace ${i + 1}\"",
        );
      }

      buffer.writeln(
        "    exec echo \"${profile.name}\" > ~/.current_kanshi_profile",
      );
      buffer.writeln("}\n");
    }

    final file = File(configPath);
    File? backup;
    try {
      if (await file.exists()) {
        backup = await file.copy(backupPath);
      }
      await file.create(recursive: true);
      await file.writeAsString(buffer.toString());
    } catch (e) {
      // Bei Fehler ggf. Backup zurückspielen
      if (backup != null && await backup.exists()) {
        await backup.copy(configPath);
      }
      rethrow;
    }
  }

  MonitorTileData _sanitizeMonitor(
      MonitorTileData m, double offsetX, double offsetY) {
    // Position nie negativ in die Config schreiben.
    final posX = (m.x + offsetX) < 0 ? 0 : (m.x + offsetX).toInt();
    final posY = (m.y + offsetY) < 0 ? 0 : (m.y + offsetY).toInt();

    // Mode validieren und ggf. auf bestes Matching aus m.modes zurückfallen.
    final bestMode = _pickBestMode(m, m.modes);

    // Breite/Höhe der Mode-Zeile müssen unrotiert sein.
    final baseW = (m.rotation % 180 == 0) ? bestMode.width : bestMode.height;
    final baseH = (m.rotation % 180 == 0) ? bestMode.height : bestMode.width;
    final refresh = bestMode.refresh > 0 ? bestMode.refresh : 60.0;

    final transform = switch (m.rotation % 360) {
      90 => '90',
      180 => '180',
      270 => '270',
      _ => 'normal',
    };

    final orientation =
        (m.rotation % 180 == 0) ? 'landscape' : 'portrait';
    final resolution = '${baseW.toInt()}x${baseH.toInt()}';

    return m.copyWith(
      x: posX.toDouble(),
      y: posY.toDouble(),
      width: baseW,
      height: baseH,
      refresh: refresh,
      resolution: resolution,
      orientation: orientation,
      rotation: m.rotation % 360,
      scale: m.scale == 0 ? 1.0 : m.scale,
      id: m.id.trim(),
      manufacturer: m.manufacturer.trim(),
    );
  }
}
