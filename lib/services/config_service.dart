import 'dart:async';
import 'dart:io';

import 'package:kanshi_gui/models/profiles.dart';
import 'package:kanshi_gui/services/kanshi_config_parser.dart';
import 'package:kanshi_gui/services/kanshi_config_writer.dart';

/// Thin filesystem layer around the kanshi config file. Parsing and rendering
/// live in [KanshiConfigParser] / [KanshiConfigWriter] respectively so they
/// can be unit-tested without touching disk.
class ConfigService {
  /// Default location of the kanshi config (`~/.config/kanshi/config`).
  final String configPath;
  final String backupPath;

  /// Write options used when serialising profiles. Defaults to a
  /// compositor-neutral profile (no Sway-specific exec lines). The Sway
  /// backend (or callers that know they target Sway) override this.
  KanshiWriteOptions writeOptions;

  ConfigService({
    String? configPath,
    String? backupPath,
    KanshiWriteOptions? writeOptions,
  })  : configPath = configPath ??
            "${Platform.environment['HOME']}/.config/kanshi/config",
        backupPath = backupPath ??
            "${Platform.environment['HOME']}/.config/kanshi/config.bak",
        writeOptions = writeOptions ?? KanshiWriteOptions.swayDefaults;

  Future<List<Profile>> loadProfiles() async {
    final file = File(configPath);
    if (!await file.exists()) return [];
    final content = await file.readAsString();
    return KanshiConfigParser.parse(content);
  }

  Future<void> saveProfiles(List<Profile> profiles) async {
    final rendered =
        KanshiConfigWriter.render(profiles, options: writeOptions);

    final file = File(configPath);
    File? backup;
    try {
      if (await file.exists()) {
        backup = await file.copy(backupPath);
      }
      await file.create(recursive: true);
      await file.writeAsString(rendered);
    } catch (e) {
      if (backup != null && await backup.exists()) {
        await backup.copy(configPath);
      }
      rethrow;
    }
  }
}
