import 'dart:developer' as Logger;
import 'dart:io';
import 'package:kanshi_gui/models/profiles.dart';
import 'package:path/path.dart' as p;
import '../models/monitor_tile_data.dart';
import 'package:kanshi_gui/utils/logger.dart';

/// Handles loading and saving of Kanshi profiles to disk.
class ConfigRepository {
  final String configDir;
  final String configFile;
  final String currentFile;

  ConfigRepository({String? home})
    : configDir = p.join(
        home ?? Platform.environment['HOME']!,
        '.config',
        'kanshi',
      ),
      configFile = p.join(
        home ?? Platform.environment['HOME']!,
        '.config',
        'kanshi',
        'config',
      ),
      currentFile = p.join(
        home ?? Platform.environment['HOME']!,
        '.config',
        'kanshi',
        'current',
      );

  /// Loads profiles by parsing the Kanshi config file.
  Future<List<Profile>> loadProfiles() async {
    final file = File(configFile);
    if (!await file.exists()) return [];
    final content = await file.readAsString();

    final List<Profile> profiles = [];
    final profileBlock = RegExp(
      r"profile\s+'([^']+)'\s*\{([^}]*)\}",
      dotAll: true,
    );
    for (final m in profileBlock.allMatches(content)) {
      final name = m.group(1)!.trim();
      final body = m.group(2)!;
      final monitors = <MonitorTileData>[];

      final outputLine = RegExp(
        r"output\s+'([^']+)'\s+enable\s+scale\s+\S+\s+transform\s+(normal|90|180|270)\s+position\s+(-?\d+),(-?\d+)",
      );
      for (final o in outputLine.allMatches(body)) {
        final id = o.group(1)!.trim();
        final transform = o.group(2)!;
        final x = double.parse(o.group(3)!);
        final y = double.parse(o.group(4)!);
        final rot = {'normal': 0, '90': 90, '180': 180, '270': 270}[transform]!;
        final isPortrait = rot % 180 != 0;
        final w = isPortrait ? 1080.0 : 1920.0;
        final h = isPortrait ? 1920.0 : 1080.0;
        final res = "\${w.toInt()}x\${h.toInt()}";
        final orient = isPortrait ? 'portrait' : 'landscape';

        monitors.add(
          MonitorTileData(
            id: id,
            manufacturer: id,
            x: x,
            y: y,
            width: w,
            height: h,
            rotation: rot,
            resolution: res,
            orientation: orient,
          ),
        );
      }
      profiles.add(Profile(name: name, monitors: monitors));
    }
    return profiles;
  }

  /// Serializes profiles back into the Kanshi config format and writes to disk.
  Future<void> saveProfiles(List<Profile> profiles) async {
    final dir = Directory(configDir);
    if (!await dir.exists()) await dir.create(recursive: true);
    final buffer = StringBuffer();

    for (final pfile in profiles) {
      buffer.writeln("profile '\${pfile.name}' {");
      int ws = 1;
      for (final m in pfile.monitors) {
        final tx = m.rotation == 0 ? 'normal' : m.rotation.toString();
        final px = m.x.toInt();
        final py = m.y.toInt();
        buffer.writeln(
          "  output '\${m.id}' enable scale 1 transform \$tx position \$px,\$py",
        );
        buffer.writeln(
          "  exec swaymsg \"workspace \$ws output '\${m.manufacturer}'; workspace \$ws\"",
        );
        ws++;
      }
      buffer.writeln("  exec echo '\${pfile.name}' > \$currentFile");
      buffer.writeln("}\n");
    }

    await File(configFile).writeAsString(buffer.toString());
    Logger.log('Profiles saved.');
  }

  /// Updates the currently active profile for Kanshi.
  Future<void> updateCurrentProfile(String name) async {
    await File(currentFile).writeAsString(name);
    Logger.log('Current profile set to \$name');
  }
}
