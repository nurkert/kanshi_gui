import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:kanshi_gui/services/kanshi_config_writer.dart';

/// User-facing tri-state for the (Sway-only) workspace-management feature.
/// [off] is the default for fresh installs so a first launch never reshuffles
/// a new user's workspaces; the other two pick how the numeric workspaces are
/// spread across monitors (see [WorkspaceDistribution]).
enum WorkspaceManagementMode {
  off,
  interleaved,
  grouped;

  /// Parses the JSON string written by [AppSettings.save]. Anything
  /// unrecognised (including null) falls back to [off].
  static WorkspaceManagementMode fromJson(Object? raw) {
    switch (raw) {
      case 'interleaved':
        return WorkspaceManagementMode.interleaved;
      case 'grouped':
        return WorkspaceManagementMode.grouped;
      default:
        return WorkspaceManagementMode.off;
    }
  }

  String get jsonValue => name;

  bool get enabled => this != WorkspaceManagementMode.off;

  /// The writer-level distribution this mode maps to, or null when
  /// management is [off]. The controller uses this to gate the Sway
  /// workspace exec injection.
  WorkspaceDistribution? get distribution {
    switch (this) {
      case WorkspaceManagementMode.off:
        return null;
      case WorkspaceManagementMode.interleaved:
        return WorkspaceDistribution.interleaved;
      case WorkspaceManagementMode.grouped:
        return WorkspaceDistribution.grouped;
    }
  }
}

/// App-wide theme preference. Defaults to [dark] to preserve the historical
/// dark-only look; [system] follows the platform brightness.
enum AppThemeChoice {
  system,
  light,
  dark;

  static AppThemeChoice fromJson(Object? raw) {
    switch (raw) {
      case 'system':
        return AppThemeChoice.system;
      case 'light':
        return AppThemeChoice.light;
      default:
        return AppThemeChoice.dark;
    }
  }

  String get jsonValue => name;
}

/// wl-mirror's `--scaling` mode for mirror destinations. [fit] (the
/// historical default) letterboxes to preserve aspect ratio; [cover] fills
/// the destination by cropping; [exact] forbids scaling.
enum MirrorScaling {
  fit,
  cover,
  exact;

  static MirrorScaling fromJson(Object? raw) {
    switch (raw) {
      case 'cover':
        return MirrorScaling.cover;
      case 'exact':
        return MirrorScaling.exact;
      default:
        return MirrorScaling.fit;
    }
  }

  String get jsonValue => name;

  /// The literal string passed to `wl-mirror --scaling`.
  String get arg => name;
}

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
  /// Whether (and how) kanshi_gui distributes Sway workspaces across the
  /// active outputs. Opt-in: defaults to [WorkspaceManagementMode.off] for
  /// fresh installs (see [load] for the upgrade migration that preserves the
  /// historical always-on behaviour for existing users).
  WorkspaceManagementMode workspaceManagement;

  // ── Behavior & timing ──────────────────────────────────────────────────
  /// Seconds the post-apply safety-net countdown runs before auto-reverting
  /// a risky mode/disable change. 0 disables the safety net entirely.
  int safetyNetSeconds;
  /// Seconds before a previewed custom mode auto-reverts if not kept.
  int customModeRevertSeconds;
  /// Show the "X connected / disconnected" toasts on hotplug.
  bool hotplugToasts;
  /// Show the "this setup matches profile Y" suggestion toast.
  bool profileSuggestionToasts;
  /// When true, an explicit Apply arms a countdown that auto-reverts to the
  /// previously-applied config unless you confirm. Off by default — most
  /// applies are routine and the countdown is intrusive; turn it on if you
  /// want the "keep these settings?" safety net for risky changes.
  bool autoRevertOnApply;
  /// When true (the default), edits go straight to the compositor as you
  /// make them and there is no Apply button. Turn it off to stage changes
  /// behind an explicit Apply.
  bool liveApply;
  /// When true, kanshi_gui automatically fires `kanshictl reload` after a
  /// hotplug if the live output positions drift away from the active
  /// profile's positions. Off by default — the drift banner still shows
  /// so the user can re-apply with one click; this flag just removes that
  /// click.
  bool autoReapplyOnDrift;

  // ── Layout & editing ───────────────────────────────────────────────────
  /// Edge/alignment snap distance in logical pixels while dragging tiles.
  double snapDistance;
  /// Raster scale onto the common HiDPI snap values on slider release.
  bool scaleSnapping;

  // ── Appearance ─────────────────────────────────────────────────────────
  AppThemeChoice themeChoice;
  /// Optional ARGB accent override. Null = derive from the Sway config.
  int? accentArgb;
  /// Seconds the identify-display number banners stay on screen.
  int identifyBannerSeconds;

  // ── Advanced & mirror ──────────────────────────────────────────────────
  MirrorScaling mirrorScaling;
  /// How many timestamped kanshi-config backups to retain.
  int maxBackups;
  /// Override for the kanshi config path. Null = the standard
  /// `~/.config/kanshi/config`. Takes effect on the next launch.
  String? kanshiConfigPath;

  // Defaults live here so [resetToDefaults] and the constructor agree.
  static const defaultSafetyNetSeconds = 15;
  static const defaultCustomModeRevertSeconds = 10;
  static const defaultSnapDistance = 60.0;
  static const defaultIdentifyBannerSeconds = 3;
  static const defaultMaxBackups = 10;

  AppSettings({
    required this.filePath,
    this.firstRunDone = false,
    this.autoSwitchProfile = true,
    this.workspaceManagement = WorkspaceManagementMode.off,
    this.safetyNetSeconds = defaultSafetyNetSeconds,
    this.customModeRevertSeconds = defaultCustomModeRevertSeconds,
    this.hotplugToasts = true,
    this.profileSuggestionToasts = true,
    this.autoRevertOnApply = false,
    this.liveApply = true,
    this.autoReapplyOnDrift = false,
    this.snapDistance = defaultSnapDistance,
    this.scaleSnapping = true,
    this.themeChoice = AppThemeChoice.dark,
    this.accentArgb,
    this.identifyBannerSeconds = defaultIdentifyBannerSeconds,
    this.mirrorScaling = MirrorScaling.fit,
    this.maxBackups = defaultMaxBackups,
    this.kanshiConfigPath,
  });

  /// Resets every user-facing preference to its default. Leaves [filePath]
  /// and [firstRunDone] untouched (we don't want to re-trigger the wizard).
  void resetToDefaults() {
    autoSwitchProfile = true;
    workspaceManagement = WorkspaceManagementMode.off;
    safetyNetSeconds = defaultSafetyNetSeconds;
    customModeRevertSeconds = defaultCustomModeRevertSeconds;
    hotplugToasts = true;
    profileSuggestionToasts = true;
    autoRevertOnApply = false;
    liveApply = true;
    autoReapplyOnDrift = false;
    snapDistance = defaultSnapDistance;
    scaleSnapping = true;
    themeChoice = AppThemeChoice.dark;
    accentArgb = null;
    identifyBannerSeconds = defaultIdentifyBannerSeconds;
    mirrorScaling = MirrorScaling.fit;
    maxBackups = defaultMaxBackups;
    kanshiConfigPath = null;
  }

  static int _int(Object? v, int def) =>
      v is int ? v : (v is num ? v.toInt() : def);
  static double _double(Object? v, double def) =>
      v is num ? v.toDouble() : def;
  static bool _bool(Object? v, bool def) => v is bool ? v : def;

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
        // Upgrade migration: a settings.json that predates this feature has
        // no `workspaceManagement` key but was written by a version where
        // workspace management was unconditionally on (interleaved). Default
        // those existing users to `interleaved` so the upgrade doesn't
        // silently stop managing their workspaces. Only fresh installs (no
        // file at all — handled above) get `off`.
        workspaceManagement: json.containsKey('workspaceManagement')
            ? WorkspaceManagementMode.fromJson(json['workspaceManagement'])
            : WorkspaceManagementMode.interleaved,
        // New keys (added after the workspace feature) simply fall back to
        // their defaults when absent — no migration needed.
        safetyNetSeconds:
            _int(json['safetyNetSeconds'], defaultSafetyNetSeconds),
        customModeRevertSeconds: _int(
            json['customModeRevertSeconds'], defaultCustomModeRevertSeconds),
        hotplugToasts: _bool(json['hotplugToasts'], true),
        profileSuggestionToasts:
            _bool(json['profileSuggestionToasts'], true),
        autoRevertOnApply: _bool(json['autoRevertOnApply'], false),
        liveApply: _bool(json['liveApply'], true),
        autoReapplyOnDrift: _bool(json['autoReapplyOnDrift'], false),
        snapDistance: _double(json['snapDistance'], defaultSnapDistance),
        scaleSnapping: _bool(json['scaleSnapping'], true),
        themeChoice: AppThemeChoice.fromJson(json['themeChoice']),
        accentArgb: json['accentArgb'] is int ? json['accentArgb'] as int : null,
        identifyBannerSeconds: _int(
            json['identifyBannerSeconds'], defaultIdentifyBannerSeconds),
        mirrorScaling: MirrorScaling.fromJson(json['mirrorScaling']),
        maxBackups: _int(json['maxBackups'], defaultMaxBackups),
        kanshiConfigPath: json['kanshiConfigPath'] is String &&
                (json['kanshiConfigPath'] as String).isNotEmpty
            ? json['kanshiConfigPath'] as String
            : null,
      );
    } catch (_) {
      return AppSettings(filePath: p);
    }
  }

  /// Serialises writes. Dragging a slider in the settings page calls [save]
  /// on every frame; each call used to race the others through one shared
  /// `<path>.tmp`, so renames landed out of order (the value written last
  /// was not necessarily the value the user let go of) and every rename that
  /// lost the race threw `PathNotFoundException` into an unhandled async
  /// error — around sixty of them per drag.
  Future<void> _chain = Future.value();

  /// A write that is queued but has not started yet. Because [_writeOnce]
  /// serialises the *current* field values at the moment it runs, one queued
  /// write is always enough: it will pick up whatever the newest values are.
  /// A burst of sixty therefore collapses into at most two writes.
  Completer<void>? _queued;

  /// Distinguishes concurrent temp files. Writes are serialised, so this is
  /// belt and braces — but two AppSettings instances pointing at the same
  /// path (tests, a second window) would otherwise share one temp name.
  static int _writeSeq = 0;

  Future<void> save() {
    final queued = _queued;
    if (queued != null) return queued.future;

    final completer = Completer<void>();
    _queued = completer;
    _chain = _chain.then((_) async {
      // Cleared before the write, not after: a save requested *during* the
      // write must queue a fresh one, because this write has already
      // serialised its values.
      _queued = null;
      try {
        await _writeOnce();
        completer.complete();
      } catch (e, st) {
        completer.completeError(e, st);
      }
    });
    return completer.future;
  }

  Future<void> _writeOnce() async {
    final json = jsonEncode({
      'firstRunDone': firstRunDone,
      'autoSwitchProfile': autoSwitchProfile,
      'workspaceManagement': workspaceManagement.jsonValue,
      'safetyNetSeconds': safetyNetSeconds,
      'customModeRevertSeconds': customModeRevertSeconds,
      'hotplugToasts': hotplugToasts,
      'profileSuggestionToasts': profileSuggestionToasts,
      'autoRevertOnApply': autoRevertOnApply,
      'liveApply': liveApply,
      'autoReapplyOnDrift': autoReapplyOnDrift,
      'snapDistance': snapDistance,
      'scaleSnapping': scaleSnapping,
      'themeChoice': themeChoice.jsonValue,
      if (accentArgb != null) 'accentArgb': accentArgb,
      'identifyBannerSeconds': identifyBannerSeconds,
      'mirrorScaling': mirrorScaling.jsonValue,
      'maxBackups': maxBackups,
      if (kanshiConfigPath != null) 'kanshiConfigPath': kanshiConfigPath,
    });
    // Atomic write: fully populate `<path>.tmp`, fsync via flush, then
    // rename over the live file. A crash mid-write leaves either the
    // old contents (still valid) or the new contents (still valid) —
    // never a half-truncated JSON that would parse-fail and silently
    // reset every setting on the next launch.
    final live = File(filePath);
    await live.create(recursive: true);
    final tmp = File('$filePath.tmp.${pid}_${_writeSeq++}');
    try {
      await tmp.writeAsString(json, flush: true);
      await tmp.rename(filePath);
    } catch (_) {
      // Never leave a stray temp file behind — the settings directory is
      // one the user may well look into.
      try {
        if (await tmp.exists()) await tmp.delete();
      } catch (_) {/* best effort */}
      rethrow;
    }
  }
}
