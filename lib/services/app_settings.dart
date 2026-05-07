import 'dart:convert';
import 'dart:io';

/// Lightweight JSON-backed app settings (the kanshi config itself stays
/// where kanshi expects it — this is for kanshi_gui-private state like the
/// first-run flag). Path: `~/.config/kanshi-gui/settings.json`.
class AppSettings {
  final String filePath;
  bool firstRunDone;
  /// When true, plugging a known monitor set in switches the GUI to the
  /// matching profile automatically (with an Undo toast). When false the
  /// hotplug listener falls back to the suggestion SnackBar.
  bool autoSwitchProfile;

  AppSettings({
    required this.filePath,
    this.firstRunDone = false,
    this.autoSwitchProfile = true,
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
        // Missing key → keep the default (true). An older settings.json
        // upgrades silently on next save.
        autoSwitchProfile: json['autoSwitchProfile'] is bool
            ? json['autoSwitchProfile'] as bool
            : true,
      );
    } catch (_) {
      return AppSettings(filePath: p);
    }
  }

  Future<void> save() async {
    final json = jsonEncode({
      'firstRunDone': firstRunDone,
      'autoSwitchProfile': autoSwitchProfile,
    });
    // Atomic write: fully populate `<path>.tmp`, fsync via flush, then
    // rename over the live file. A crash mid-write leaves either the
    // old contents (still valid) or the new contents (still valid) —
    // never a half-truncated JSON that would parse-fail and silently
    // reset every setting on the next launch.
    final live = File(filePath);
    await live.create(recursive: true);
    final tmp = File('$filePath.tmp');
    await tmp.writeAsString(json, flush: true);
    await tmp.rename(filePath);
  }
}
