import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:kanshi_gui/models/monitor_mode.dart';
import 'package:kanshi_gui/models/monitor_tile_data.dart';
import 'package:kanshi_gui/models/profiles.dart';
import 'package:kanshi_gui/services/config_service.dart';
import 'package:kanshi_gui/services/layout_math.dart';
import 'package:kanshi_gui/services/monitor_service.dart';
import 'package:kanshi_gui/state/custom_mode_revert_scheduler.dart';

/// Lightweight result type returned by mutating controller operations so the
/// UI can decide whether to show a snackbar. Avoids leaking [ProcessResult]
/// or stack traces into the widget tree.
class OpResult {
  final bool success;
  final String? message;
  const OpResult.ok([this.message]) : success = true;
  const OpResult.err(this.message) : success = false;
}

/// Holds the live application state (profiles, currently connected outputs,
/// active profile) and orchestrates compositor + config-file mutations.
/// All UI state changes happen through this controller; widgets observe via
/// [ListenableBuilder] / [AnimatedBuilder].
class KanshiController extends ChangeNotifier {
  final MonitorService monitors;
  final ConfigService config;
  final CustomModeRevertScheduler _revertScheduler =
      CustomModeRevertScheduler();

  /// Snap distance used by the layout helpers. Public so widgets that need
  /// to mirror the value (e.g. for cursor hints) can read it.
  final double snapThreshold;

  List<Profile> _profiles = [];
  List<MonitorTileData> _currentMonitors = [];
  int? _activeProfileIndex;
  bool _isApplyingBatch = false;
  Timer? _saveTimer;
  final Map<String, MonitorMode> _lastModeBeforeCustom = {};

  KanshiController({
    required this.monitors,
    required this.config,
    this.snapThreshold = 500.0,
  }) {
    config.writeOptions = monitors.writeOptions;
  }

  // ── Read-only accessors ────────────────────────────────────────────────
  List<Profile> get profiles => List.unmodifiable(_profiles);
  List<MonitorTileData> get currentMonitors =>
      List.unmodifiable(_currentMonitors);
  int? get activeProfileIndex => _activeProfileIndex;
  Profile? get activeProfile =>
      _activeProfileIndex == null ? null : _profiles[_activeProfileIndex!];
  List<MonitorTileData> get activeMonitors =>
      activeProfile?.monitors ?? const [];
  bool get isApplyingBatch => _isApplyingBatch;
  bool get supportsLiveApply => monitors.isLive;

  // ── Lifecycle ──────────────────────────────────────────────────────────
  Future<void> init() async {
    await _loadConfig();
    await refreshConnectedMonitors();
    await ensureCurrentSetupMatches();
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    _revertScheduler.cancelAll();
    super.dispose();
  }

  // ── Profile mutations ──────────────────────────────────────────────────
  Future<void> _loadConfig() async {
    _profiles = await config.loadProfiles();
    _activeProfileIndex = _findProfileMatchingCurrent() ??
        (_profiles.isNotEmpty ? 0 : null);
    notifyListeners();
  }

  Future<void> refreshConnectedMonitors() async {
    if (!monitors.isLive) {
      _currentMonitors = [];
      notifyListeners();
      return;
    }
    try {
      _currentMonitors = await monitors.getOutputs();
      // Re-hydrate profile entries with the live mode list / refresh / id.
      for (final profile in _profiles) {
        for (var i = 0; i < profile.monitors.length; i++) {
          final connected = _currentMonitors.firstWhere(
            (m) => _monitorsMatch(m, profile.monitors[i]),
            orElse: () => profile.monitors[i],
          );
          profile.monitors[i] = profile.monitors[i].copyWith(
            id: connected.id,
            manufacturer: connected.manufacturer,
            refresh: connected.refresh,
            modes: connected.modes,
          );
        }
      }
      notifyListeners();
    } catch (e) {
      debugPrint('refreshConnectedMonitors failed: $e');
    }
  }

  Future<void> ensureCurrentSetupMatches() async {
    final matchIdx = _findProfileMatchingCurrent();
    if (matchIdx != null) {
      _activeProfileIndex = matchIdx;
    } else {
      const currentName = 'Current Setup';
      final idx = _profiles.indexWhere((p) => p.name == currentName);
      if (idx == -1) {
        _profiles.add(Profile(name: currentName, monitors: _currentMonitors));
        _activeProfileIndex = _profiles.length - 1;
      } else {
        _profiles[idx] =
            Profile(name: currentName, monitors: _currentMonitors);
        _activeProfileIndex = idx;
      }
    }

    final home = Platform.environment['HOME'] ?? '';
    if (home.isNotEmpty) {
      final marker = File('$home/.config/kanshi/current');
      try {
        await marker.create(recursive: true);
        await marker.writeAsString(activeProfile?.name ?? 'Current Setup');
      } catch (e) {
        debugPrint('failed to write current profile marker: $e');
      }
    }
    _scheduleSave();
    notifyListeners();
  }

  void setActiveProfile(int index) {
    _activeProfileIndex = index;
    notifyListeners();
  }

  OpResult renameProfile(int index, String newName) {
    final exists = _profiles.any((p) =>
        p.name.toLowerCase() == newName.toLowerCase() &&
        p != _profiles[index]);
    if (exists) {
      return const OpResult.err('Profile name already exists!');
    }
    _profiles[index].name = newName;
    _scheduleSave();
    notifyListeners();
    return const OpResult.ok();
  }

  void deleteProfile(int index) {
    if (_activeProfileIndex == index) _activeProfileIndex = null;
    _profiles.removeAt(index);
    _scheduleSave();
    notifyListeners();
  }

  void createProfileFromCurrentSetup() {
    final newProfile = Profile(
      name: 'Current Setup',
      monitors: _currentMonitors.map((m) {
        return m.rotation % 180 == 0
            ? m.copyWith(orientation: 'landscape')
            : m.copyWith(
                width: m.height,
                height: m.width,
                orientation: 'portrait',
              );
      }).toList(),
    );
    _profiles.add(newProfile);
    _activeProfileIndex = _profiles.length - 1;
    _scheduleSave();
    notifyListeners();
  }

  // ── Monitor-level mutations within the active profile ──────────────────
  void updateMonitor(MonitorTileData updated) {
    if (_activeProfileIndex == null) return;
    final mons = _profiles[_activeProfileIndex!].monitors;
    final idx = mons.indexWhere((m) => m.id == updated.id);
    if (idx == -1) return;
    if (!mons[idx].enabled) return;
    mons[idx] = updated;
    _scheduleSave();
    notifyListeners();
  }

  void scaleMonitor(String id, double newScale) {
    if (_activeProfileIndex == null) return;
    for (var n = 1; n <= 8; n++) {
      if ((newScale - n).abs() < 0.05) {
        newScale = n.toDouble();
        break;
      }
    }
    newScale = double.parse(newScale.toStringAsFixed(2));

    final mons = [..._profiles[_activeProfileIndex!].monitors];
    final idx = mons.indexWhere((m) => m.id == id);
    if (idx == -1 || !mons[idx].enabled) return;

    final centre = mons[idx];
    for (var i = 0; i < mons.length; i++) {
      if (i == idx) continue;
      var other = mons[i];
      final centreRight = centre.x + centre.width / centre.scale;
      final centreBottom = centre.y + centre.height / centre.scale;
      if ((other.x - centreRight).abs() <= snapThreshold) {
        other = other.copyWith(x: centre.x + centre.width / newScale);
      } else if (((other.x + other.width / other.scale) - centre.x).abs() <=
          snapThreshold) {
        other = other.copyWith(x: centre.x - other.width / other.scale);
      }
      if ((other.y - centreBottom).abs() <= snapThreshold) {
        other = other.copyWith(y: centre.y + centre.height / newScale);
      } else if (((other.y + other.height / other.scale) - centre.y).abs() <=
          snapThreshold) {
        other = other.copyWith(y: centre.y - other.height / other.scale);
      }
      mons[i] = other;
    }
    mons[idx] = centre.copyWith(scale: newScale);
    _profiles[_activeProfileIndex!] =
        Profile(name: _profiles[_activeProfileIndex!].name, monitors: mons);
    _scheduleSave();
    notifyListeners();
  }

  void snapAndCommit(MonitorTileData dragged, MonitorTileData? rollbackTo) {
    if (_activeProfileIndex == null) return;
    final mons = [..._profiles[_activeProfileIndex!].monitors];
    final idx = mons.indexWhere((m) => m.id == dragged.id);
    if (idx == -1 || !mons[idx].enabled) return;
    final snapped =
        LayoutMath.snapToEdges(mons[idx], mons, snapThreshold);
    mons[idx] = snapped;
    if (LayoutMath.hasOverlap(snapped, mons, idx) && rollbackTo != null) {
      mons[idx] = rollbackTo;
    }
    _profiles[_activeProfileIndex!] =
        Profile(name: _profiles[_activeProfileIndex!].name, monitors: mons);
    _scheduleSave();
    notifyListeners();
  }

  void rearrangeActiveLayout() {
    if (_activeProfileIndex == null) return;
    final profile = _profiles[_activeProfileIndex!];
    final active = profile.monitors.where((m) => m.enabled).toList()
      ..sort((a, b) => a.x.compareTo(b.x));
    final inactive = profile.monitors.where((m) => !m.enabled).toList()
      ..sort((a, b) => a.x.compareTo(b.x));
    if (active.isEmpty) return;

    const spacing = 100.0;
    var currentX = 0.0;
    final rearranged = <MonitorTileData>[];
    double advance(MonitorTileData m) =>
        m.width / (m.scale == 0 ? 1.0 : m.scale);
    for (final m in active) {
      rearranged.add(m.copyWith(x: currentX, y: 0));
      currentX += advance(m) + spacing;
    }
    for (final m in inactive) {
      rearranged.add(m.copyWith(x: currentX, y: 0));
      currentX += advance(m) + spacing;
    }
    _profiles[_activeProfileIndex!] =
        Profile(name: profile.name, monitors: rearranged);
    _scheduleSave();
    notifyListeners();
  }

  // ── Compositor-driven actions ──────────────────────────────────────────
  Future<OpResult> toggleEnabled(String id, bool enabled) async {
    if (_activeProfileIndex == null) return const OpResult.err('No profile.');
    final mons = _profiles[_activeProfileIndex!].monitors;
    final idx = mons.indexWhere((m) => m.id == id);
    if (idx == -1) return const OpResult.err('Output not found.');

    final target = _resolveOutputName(id);
    final currentMode = _currentModeForOutput(target);
    if (currentMode == null) {
      return OpResult.err('Output $target not found.');
    }

    try {
      if (!enabled) {
        final r = await monitors.disable(target);
        if (r.exitCode != 0) {
          return OpResult.err(
              'Could not toggle output $target: ${r.stderr}');
        }
      } else {
        final r1 = await monitors.enable(target);
        if (r1.exitCode != 0) {
          return OpResult.err(
              'Could not enable output $target: ${r1.stderr}');
        }
        final r2 = await monitors.apply(mons[idx]);
        if (r2.exitCode != 0) {
          return OpResult.err(
              'Enabled, but failed to set mode: ${r2.stderr}');
        }
      }
    } catch (e) {
      return OpResult.err('Error while toggling: $e');
    }

    await refreshConnectedMonitors();

    final live = _currentMonitors.any((m) =>
        _normalizeOutputId(m.id) == _normalizeOutputId(target) &&
        m.enabled == enabled);
    if (live) {
      mons[idx] = mons[idx].copyWith(enabled: enabled);
      _scheduleSave();
      notifyListeners();
      return OpResult.ok(enabled
          ? 'Output enabled.'
          : 'Output disabled.');
    } else {
      return OpResult.err(
          "Output ${enabled ? 'not enabled' : 'not disabled'} - status unchanged.");
    }
  }

  Future<OpResult> applyMode(String id, MonitorMode mode) async {
    if (_activeProfileIndex == null) return const OpResult.err('No profile.');
    final mons = _profiles[_activeProfileIndex!].monitors;
    final idx = mons.indexWhere((m) => m.id == id);
    if (idx == -1) return const OpResult.err('Output not found.');

    if (mons[idx].enabled) {
      final target = _resolveOutputName(id);
      try {
        final r = await monitors.setMode(target, mode);
        if (r.exitCode != 0) {
          return OpResult.err('Failed to set mode: ${r.stderr}');
        }
      } catch (e) {
        return OpResult.err('Error setting mode: $e');
      }
      await refreshConnectedMonitors();
    }

    final rotation = mons[idx].rotation;
    final rotW = rotation % 180 == 0 ? mode.width : mode.height;
    final rotH = rotation % 180 == 0 ? mode.height : mode.width;
    mons[idx] = mons[idx].copyWith(
      width: rotW,
      height: rotH,
      refresh: mode.refresh,
      resolution: '${rotW.toInt()}x${rotH.toInt()}',
      orientation: rotation % 180 == 0
          ? (mode.width >= mode.height ? 'landscape' : 'portrait')
          : (mode.width >= mode.height ? 'portrait' : 'landscape'),
    );
    _scheduleSave();
    notifyListeners();
    return const OpResult.ok();
  }

  Future<OpResult> applyCustomMode(
    String id,
    double w,
    double h,
    double hz, {
    void Function(String, String)? onScheduledRevert,
  }) async {
    final target = _resolveOutputName(id);
    final current = _currentModeForOutput(target);
    if (current != null) {
      _lastModeBeforeCustom[target] = current;
    }
    try {
      final r = await monitors.applyCustomMode(target, w, h, hz);
      if (r.exitCode != 0) {
        return OpResult.err('Custom mode failed: ${r.stderr}');
      }
    } catch (e) {
      return OpResult.err('Custom mode failed: $e');
    }
    await refreshConnectedMonitors();

    if (_activeProfileIndex != null) {
      final mons = _profiles[_activeProfileIndex!].monitors;
      final idx = mons.indexWhere(
          (m) => _normalizeOutputId(m.id) == _normalizeOutputId(target));
      if (idx != -1) {
        final rot = mons[idx].rotation;
        final rotW = rot % 180 == 0 ? w : h;
        final rotH = rot % 180 == 0 ? h : w;
        mons[idx] = mons[idx].copyWith(
          width: rotW,
          height: rotH,
          refresh: hz,
          resolution: '${rotW.toInt()}x${rotH.toInt()}',
          orientation: rot % 180 == 0
              ? (w >= h ? 'landscape' : 'portrait')
              : (w >= h ? 'portrait' : 'landscape'),
        );
        _scheduleSave();
        notifyListeners();
      }
    }
    final label = '${w.toInt()}x${h.toInt()}@${_formatHz(hz)}Hz';
    _revertScheduler.schedule(target, () => revertCustomMode(id));
    onScheduledRevert?.call(target, label);
    return OpResult.ok('Applied custom mode: $label on $target');
  }

  Future<OpResult> revertCustomMode(String id) async {
    final target = _resolveOutputName(id);
    final last = _lastModeBeforeCustom[target];
    if (last == null) {
      return const OpResult.err('No saved custom mode to revert.');
    }
    final r = await applyMode(id, last);
    _lastModeBeforeCustom.remove(target);
    _revertScheduler.cancel(target);
    if (!r.success) return r;
    return const OpResult.ok('Custom mode reverted.');
  }

  void keepCustomMode(String id) {
    _revertScheduler.cancel(_resolveOutputName(id));
  }

  Future<OpResult> enableAllOutputs() async {
    if (_isApplyingBatch) return const OpResult.err('Busy.');
    _isApplyingBatch = true;
    notifyListeners();
    try {
      final outputs = await monitors.getOutputs();
      var ok = 0;
      final failures = <String>[];
      for (final o in outputs) {
        try {
          final r = await monitors.enable(o.id);
          if (r.exitCode != 0) {
            final err = '${r.stderr}'.trim();
            failures.add(
                '${o.manufacturer} (${err.isEmpty ? 'Unknown error' : err})');
          } else {
            ok++;
          }
        } catch (e) {
          failures.add('${o.manufacturer} ($e)');
        }
      }
      await refreshConnectedMonitors();
      await ensureCurrentSetupMatches();
      if (outputs.isEmpty) return const OpResult.ok('No outputs found.');
      if (failures.isEmpty) {
        return OpResult.ok('All ${outputs.length} outputs were enabled successfully.');
      }
      return OpResult.ok(
          'Enabled: $ok/${outputs.length}. Errors: ${failures.join(', ')}');
    } catch (e) {
      return OpResult.err('Failed to enable outputs: $e');
    } finally {
      _isApplyingBatch = false;
      notifyListeners();
    }
  }

  Future<OpResult> reloadAndApply() async {
    try {
      await config.saveProfiles(_profiles);
      final r = await monitors.restartCompositorProfileApply();
      if (r.exitCode != 0) {
        return OpResult.err('kanshi restart failed: ${r.stderr}');
      }
      await refreshConnectedMonitors();
      await _loadConfig();
      return const OpResult.ok('Reloaded and restarted kanshi.');
    } catch (e) {
      return OpResult.err('Reload failed: $e');
    }
  }

  Future<OpResult> reloadOnly() async {
    try {
      await refreshConnectedMonitors();
      await _loadConfig();
      return const OpResult.ok('Outputs and profiles refreshed.');
    } catch (e) {
      return OpResult.err('Reload failed: $e');
    }
  }

  Future<OpResult> saveProfilesOnly() async {
    try {
      await config.saveProfiles(_profiles);
      return const OpResult.ok('Profiles saved.');
    } catch (e) {
      return OpResult.err('Save failed: $e');
    }
  }

  Future<OpResult> restartCompositorService() async {
    try {
      final r = await monitors.restartCompositorProfileApply();
      if (r.exitCode != 0) {
        return OpResult.err('Error: ${r.stderr}');
      }
      return const OpResult.ok('kanshi has been (re)started.');
    } catch (e) {
      return OpResult.err('Exception: $e');
    }
  }

  Future<OpResult> restoreBackupAndApply() async {
    try {
      final backup = File(config.backupPath);
      if (!await backup.exists()) {
        return const OpResult.err('No backup found.');
      }
      await backup.copy(config.configPath);
      final r = await reloadAndApply();
      return r.success
          ? const OpResult.ok('Backup restored.')
          : r;
    } catch (e) {
      return OpResult.err('Backup restore failed: $e');
    }
  }

  // ── Helpers exposed for UI ─────────────────────────────────────────────
  MonitorMode? currentModeForOutput(String id) =>
      _currentModeForOutput(_resolveOutputName(id));

  bool monitorIsConnected(MonitorTileData m) =>
      _currentMonitors.any((c) => _matchesOutput(c.id, m.id));

  // ── Internals ──────────────────────────────────────────────────────────
  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 600), () {
      config.saveProfiles(_profiles);
    });
  }

  String _normalizeOutputId(String value) =>
      value.replaceAll(RegExp(r'\s+'), ' ').trim().toLowerCase();

  bool _matchesOutput(String a, String b) =>
      _normalizeOutputId(a) == _normalizeOutputId(b);

  bool _monitorsMatch(MonitorTileData a, MonitorTileData b) =>
      _matchesOutput(a.id, b.id) ||
      _matchesOutput(a.manufacturer, b.manufacturer);

  String _resolveOutputName(String idOrManufacturer) {
    final norm = _normalizeOutputId(idOrManufacturer);
    for (final m in _currentMonitors) {
      if (_normalizeOutputId(m.id) == norm ||
          _normalizeOutputId(m.manufacturer) == norm) {
        return m.id;
      }
    }
    return idOrManufacturer;
  }

  int? _findProfileMatchingCurrent() {
    final currentEnabled =
        _currentMonitors.where((m) => m.enabled).toList();
    for (var i = 0; i < _profiles.length; i++) {
      final enabled =
          _profiles[i].monitors.where((m) => m.enabled).toList();
      if (enabled.length != currentEnabled.length) continue;
      var allMatch = true;
      for (final cm in currentEnabled) {
        if (!enabled.any((pm) => _monitorsMatch(pm, cm))) {
          allMatch = false;
          break;
        }
      }
      if (allMatch) return i;
    }
    return null;
  }

  MonitorMode? _currentModeForOutput(String id) {
    final norm = _normalizeOutputId(id);
    final m =
        _currentMonitors.where((o) => _normalizeOutputId(o.id) == norm).toList();
    if (m.isEmpty) return null;
    return MonitorMode(
      width: m.first.width,
      height: m.first.height,
      refresh: m.first.refresh,
    );
  }

  String _formatHz(double hz) {
    final isInt = (hz - hz.round()).abs() < 0.01;
    return isInt ? hz.round().toString() : hz.toStringAsFixed(3);
  }

  bool wouldExceedBandwidth(List<MonitorTileData> mons) =>
      LayoutMath.totalPixelRate(mons) > 700000000;
}
