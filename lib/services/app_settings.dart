import 'dart:convert';
import 'dart:io';

/// Lightweight JSON-backed app settings (the kanshi config itself stays
/// where kanshi expects it — this is for kanshi_gui-private state like the
/// first-run flag). Path: `~/.config/kanshi-gui/settings.json`.
class AppSettings {
  final String filePath;
  bool firstRunDone;

  AppSettings({
    required this.filePath,
    this.firstRunDone = false,
  });

  static String _defaultPath() {
    final home = Platform.environment['HOME'] ?? '';
    return '$home/.config/kanshi-gui/settings.json';
  }

  static Future<AppSettings> load({String? path}) async {
    final p = path ?? _defaultPath();
    final file = File(p);
    if (!await file.exists()) {
      return AppSettings(filePath: p);
    }
    try {
      final raw = await file.readAsString();
      final json = jsonDecode(raw) as Map<String, dynamic>;
      return AppSettings(
        filePath: p,
        firstRunDone: json['firstRunDone'] == true,
      );
    } catch (_) {
      return AppSettings(filePath: p);
    }
  }

  Future<void> save() async {
    final file = File(filePath);
    await file.create(recursive: true);
    await file.writeAsString(jsonEncode({
      'firstRunDone': firstRunDone,
    }));
  }
}
