import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:kanshi_gui/models/monitor_tile_data.dart';
import 'package:kanshi_gui/models/monitor_mode.dart';
import 'package:kanshi_gui/models/profiles.dart';
import 'package:kanshi_gui/services/config_service.dart';
import 'package:kanshi_gui/widgets/monitor_tile.dart';
import 'package:kanshi_gui/widgets/profile_list_item.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  _HomePageState createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with SingleTickerProviderStateMixin {
  final ConfigService _configService = ConfigService();
  static const MethodChannel _nativeMenuChannel =
      MethodChannel('kanshi_gui/native_menu');

  /// Geladene Profile aus der Konfiguration.
  List<Profile> profiles = [];

  /// Aktuell verbundene Monitore.
  List<MonitorTileData> currentMonitors = [];
  final Map<String, MonitorMode> _lastModeBeforeCustom = {};
  final Map<String, Timer> _customModeRevertTimers = {};

  /// Controller für das Menü‑Icon.
  late final AnimationController _iconController;

  @override
  void initState() {
    super.initState();
    _iconController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    _nativeMenuChannel.setMethodCallHandler(_handleNativeMenuSelect);
    _initSetup();
  }

  @override
  void dispose() {
    _iconController.dispose();
    for (final t in _customModeRevertTimers.values) {
      t.cancel();
    }
    super.dispose();
  }

  Future<void> _initSetup() async {
    await _loadConfig();
    await _updateConnectedMonitors();
    await ensureCurrentSetupMatchesConnectedMonitors();
  }

  Future<List<MonitorTileData>> getConnectedMonitors() async {
    final result = await Process.run('swaymsg', ['-t', 'get_outputs']);
    if (result.exitCode != 0) {
      throw Exception('swaymsg failed: ${result.stderr}');
    }
    final outputs = jsonDecode(result.stdout) as List;
    List<MonitorTileData> monitors = [];
    for (final output in outputs) {
      final isActive = output['active'] == true;
      final make = (output['make'] ?? 'Unknown').toString().trim();
      final model = (output['model'] ?? 'Unknown').toString().trim();
      final serial = (output['serial'] ?? 'Unknown').toString().trim();
      String fullName = '$make $model $serial'
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      final outputName = (output['name'] ?? fullName).toString().trim();

      final modeMaps = (output['modes'] as List).cast<Map<String, dynamic>>();
      final modes = modeMaps
          .map((m) => MonitorMode(
                width: (m['width'] as num).toDouble(),
                height: (m['height'] as num).toDouble(),
                refresh: ((m['refresh'] as num).toDouble() / 1000.0),
              ))
          .toList();

      Map<String, dynamic>? currentMode =
          (output['current_mode'] as Map<String, dynamic>?);
      if (currentMode == null && modeMaps.isNotEmpty) {
        // Fallback: best mode by resolution then refresh
        currentMode = modeMaps.reduce((a, b) {
          int aPx = a['width'] * a['height'];
          int bPx = b['width'] * b['height'];
          if (aPx != bPx) return aPx > bPx ? a : b;
          return (a['refresh'] > b['refresh']) ? a : b;
        });
      }

      final width = (currentMode?['width'] as num?)?.toDouble() ?? 1920.0;
      final height = (currentMode?['height'] as num?)?.toDouble() ?? 1080.0;
      final refresh =
          ((currentMode?['refresh'] as num?)?.toDouble() ?? 60000.0) / 1000.0;
      double scale = (output['scale'] as num?)?.toDouble() ?? 1.0;
      String transform = (output['transform'] ?? 'normal').toString();
      int rotation = switch (transform) {
        '90' || 'flipped-90' => 90,
        '180' || 'flipped-180' => 180,
        '270' || 'flipped-270' => 270,
        _ => 0,
      };
      String orientation = (rotation % 180 == 0)
          ? (width >= height ? 'landscape' : 'portrait')
          : (width >= height ? 'portrait' : 'landscape');
      monitors.add(MonitorTileData(
        id: outputName,
        manufacturer: fullName,
        x: (output['rect']['x'] as num).toDouble(),
        y: (output['rect']['y'] as num).toDouble(),
        width: width,
        height: height,
        scale: scale,
        rotation: rotation,
        refresh: refresh,
        resolution: '${width.toInt()}x${height.toInt()}',
        orientation: orientation,
        modes: modes,
        enabled: isActive,
      ));
    }
    return monitors;
  }

  /// Stellt sicher, dass es genau ein Profil mit dem aktuellen Layout gibt.
  Future<void> ensureCurrentSetupMatchesConnectedMonitors() async {
    List<MonitorTileData> connected = await getConnectedMonitors();

    // 1) Prüfe, ob bereits irgendein Profil exakt diese Monitore hat.
    int? matchIndex = _findProfileWithAllCurrentMonitors();
    if (matchIndex != null) {
      // Aktiviere das gefundene Profil
      setState(() {
        activeProfileIndex = matchIndex;
      });
    } else {
      // 2) Sonst erstelle oder aktualisiere das Profil "Current Setup"
      const currentName = 'Current Setup';
      int currentIndex = profiles.indexWhere((p) => p.name == currentName);
      if (currentIndex == -1) {
        // Profil anlegen
        Profile currentSetup = Profile(name: currentName, monitors: connected);
        setState(() {
          profiles.add(currentSetup);
          activeProfileIndex = profiles.length - 1;
        });
      } else {
        // Bestehendes "Current Setup" updaten
        setState(() {
          profiles[currentIndex] =
              Profile(name: currentName, monitors: connected);
          activeProfileIndex = currentIndex;
        });
      }
    }

    // 3) Schreibe die aktive Profilbezeichnung in ~/.config/kanshi/current
    final home = Platform.environment['HOME'] ?? '';
    final file = File('$home/.config/kanshi/current');
    await file.create(recursive: true);
    final activeName = activeProfileIndex != null
        ? profiles[activeProfileIndex!].name
        : 'Current Setup';
    await file.writeAsString(activeName);

    _autoSave();
  }

  int? activeProfileIndex;
  bool _isSidebarOpen = false;
  final double snapThreshold = 500.0;
  double _scaleFactor = 1.0;
  double _offsetX = 0;
  double _offsetY = 0;
  List<MonitorTileData> _displayMonitors = [];
  final Map<String, MonitorTileData> _oldPositionsBeforeDrag = {};
  Timer? _saveTimer;
  bool _isEnablingOutputs = false;

  String _normalizeOutputId(String value) {
    return value.replaceAll(RegExp(r'\s+'), ' ').trim().toLowerCase();
  }

  bool _monitorsMatch(MonitorTileData a, MonitorTileData b) {
    return _matchesOutput(a.id, b.id) ||
        _matchesOutput(a.manufacturer, b.manufacturer);
  }

  String _resolveOutputName(String idOrManufacturer) {
    final norm = _normalizeOutputId(idOrManufacturer);
    for (final m in currentMonitors) {
      if (_normalizeOutputId(m.id) == norm ||
          _normalizeOutputId(m.manufacturer) == norm) {
        return m.id;
      }
    }
    return idOrManufacturer;
  }

  Future<void> _enableAllOutputs() async {
    if (_isEnablingOutputs) return;
    if (!mounted) return;

    setState(() {
      _isEnablingOutputs = true;
    });

    try {
      final result = await Process.run('swaymsg', ['-t', 'get_outputs']);
      if (result.exitCode != 0) {
        throw Exception('swaymsg failed: ${result.stderr}');
      }

      final outputs = (jsonDecode(result.stdout) as List).cast<Map<String, dynamic>>();
      int successCount = 0;
      final List<String> failures = [];

      for (final output in outputs) {
        final make = (output['make'] ?? 'Unknown').toString().trim();
        final model = (output['model'] ?? 'Unknown').toString().trim();
        final serial = (output['serial'] ?? 'Unknown').toString().trim();
        final fullName = '$make $model $serial'
            .replaceAll(RegExp(r'\s+'), ' ')
            .trim();
        final outputName = (output['name'] ?? fullName).toString().trim();

        try {
          final enableResult =
              await Process.run('swaymsg', ['output', outputName, 'enable']);
          if (enableResult.exitCode != 0) {
            final rawError = '${enableResult.stderr}'.trim();
            final errorMessage =
                rawError.isEmpty || rawError == 'null' ? 'Unknown error' : rawError;
            debugPrint('Failed to enable output $fullName: $errorMessage');
            failures.add('$fullName ($errorMessage)');
          } else {
            successCount++;
          }
        } catch (e) {
          debugPrint('Error enabling output $fullName: $e');
          failures.add('$fullName ($e)');
        }
      }

      String message;
      if (outputs.isEmpty) {
        message = 'No outputs found.';
      } else if (failures.isEmpty) {
        message =
            'All ${outputs.length} outputs were enabled successfully.';
      } else {
        message =
            'Enabled: $successCount/${outputs.length}. Errors: ${failures.join(', ')}';
      }

      await _updateConnectedMonitors();
      if (mounted) {
        await ensureCurrentSetupMatchesConnectedMonitors();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(message)),
        );
      }
    } catch (e) {
      debugPrint('Error enabling all outputs: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to enable outputs: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isEnablingOutputs = false;
        });
      }
    }
  }

  Future<void> _repairActiveLayout() async {
    if (activeProfileIndex == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No active profile to rearrange.')),
      );
      return;
    }

    final profile = profiles[activeProfileIndex!];
    final activeMonitors = profile.monitors.where((m) => m.enabled).toList()
      ..sort((a, b) => a.x.compareTo(b.x));
    final inactiveMonitors =
        profile.monitors.where((m) => !m.enabled).toList()
          ..sort((a, b) => a.x.compareTo(b.x));

    if (activeMonitors.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No active monitors to rearrange.')),
      );
      return;
    }

    const double spacing = 100.0;
    double currentX = 0.0;
    final List<MonitorTileData> rearranged = [];

    double _nextPosition(MonitorTileData monitor) {
      final scale = monitor.scale == 0 ? 1.0 : monitor.scale;
      return monitor.width / scale;
    }

    for (final monitor in activeMonitors) {
      rearranged.add(monitor.copyWith(x: currentX, y: 0));
      currentX += _nextPosition(monitor) + spacing;
    }

    for (final monitor in inactiveMonitors) {
      rearranged.add(monitor.copyWith(x: currentX, y: 0));
      currentX += _nextPosition(monitor) + spacing;
    }

    if (!mounted) return;

    setState(() {
      profiles[activeProfileIndex!] =
          Profile(name: profile.name, monitors: rearranged);
    });

    _autoSave();

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
            'Rearranged layout for ${activeMonitors.length} active monitor${activeMonitors.length == 1 ? '' : 's'}.'),
      ),
    );
  }

  bool _matchesOutput(String a, String b) {
    return _normalizeOutputId(a) == _normalizeOutputId(b);
  }

  List<MonitorTileData> get activeMonitors {
    if (activeProfileIndex == null) return [];
    return profiles[activeProfileIndex!].monitors;
  }

  Future<void> _updateConnectedMonitors() async {
    try {
      List<MonitorTileData> monitors = await getConnectedMonitors();
      if (!mounted) return;
      setState(() {
        currentMonitors = monitors;
        for (final profile in profiles) {
          for (var i = 0; i < profile.monitors.length; i++) {
            final connected = monitors.firstWhere(
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
      });
    } catch (e) {
      debugPrint('Error getting connected monitors: $e');
    }
  }

  Future<void> _waitForOutputState(String id,
      {required bool shouldExist}) async {
    const pollInterval = Duration(milliseconds: 250);
    const timeout = Duration(seconds: 5);
    final normalizedId = _normalizeOutputId(id);
    final deadline = DateTime.now().add(timeout);

    while (mounted && DateTime.now().isBefore(deadline)) {
      final matches = currentMonitors
          .where((m) => _normalizeOutputId(m.id) == normalizedId)
          .toList();
      final exists = matches.isNotEmpty;
      final isEnabled = matches.any((m) => m.enabled);
      if ((shouldExist && isEnabled) ||
          (!shouldExist && (!exists || !isEnabled))) {
        return;
      }
      await Future.delayed(pollInterval);
      await _updateConnectedMonitors();
    }

    if (mounted) {
      debugPrint(
          'Timeout waiting for output "$id" to ${shouldExist ? 'appear' : 'disappear'}.');
    }
  }

  Future<void> _loadConfig() async {
    List<Profile> loaded = await _configService.loadProfiles();
    setState(() {
      profiles = loaded;
      activeProfileIndex = _findProfileWithAllCurrentMonitors() ??
          (profiles.isNotEmpty ? 0 : null);
      _isSidebarOpen = activeProfileIndex == null;
    });
  }

  void _debouncedAutoSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(
      const Duration(milliseconds: 600),
      () => _configService.saveProfiles(profiles),
    );
  }

  void _autoSave() => _debouncedAutoSave();

  void _updateDisplayMonitors(BoxConstraints constraints) {
    final mons = activeMonitors;
    if (mons.isEmpty) {
      _displayMonitors = [];
      return;
    }
    final boundsSource = mons;
    double minX = boundsSource.map((m) => m.x).reduce(min);
    double minY = boundsSource.map((m) => m.y).reduce(min);
    double maxX = boundsSource
        .map((m) => m.x + m.width / m.scale)
        .reduce(max);
    double maxY = boundsSource
        .map((m) => m.y + m.height / m.scale)
        .reduce(max);
    double boundingWidth = maxX - minX;
    double boundingHeight = maxY - minY;
    double allowedW = constraints.maxWidth * 0.8;
    double allowedH = constraints.maxHeight * 0.8;
    double scaleX = boundingWidth == 0 ? 1 : allowedW / boundingWidth;
    double scaleY = boundingHeight == 0 ? 1 : allowedH / boundingHeight;
    double scale = min(scaleX, scaleY);
    _scaleFactor = scale > 1.0 ? 1.0 : scale;
    double scaledBW = boundingWidth * _scaleFactor;
    double scaledBH = boundingHeight * _scaleFactor;
    _offsetX = (constraints.maxWidth - scaledBW) / 2;
    _offsetY = (constraints.maxHeight - scaledBH) / 2;
    _displayMonitors = mons.map((m) {
      double dx = (m.x - minX) * _scaleFactor + _offsetX;
      double dy = (m.y - minY) * _scaleFactor + _offsetY;
      double dw = (m.width / m.scale) * _scaleFactor;
      double dh = (m.height / m.scale) * _scaleFactor;
      return m.copyWith(
        x: dx,
        y: dy,
        width: dw,
        height: dh,
      );
    }).toList();
  }

  void _onMonitorUpdate(MonitorTileData updatedTile, BoxConstraints constraints) {
    if (activeProfileIndex == null) return;
    final mons = activeMonitors;
    final index = mons.indexWhere((m) => m.id == updatedTile.id);
    if (index == -1) return;
    final oldMonitor = mons[index];
    if (!oldMonitor.enabled) return;
    final oldRotation = oldMonitor.rotation;
    final newRotation = updatedTile.rotation;
    double newWidth = oldMonitor.width;
    double newHeight = oldMonitor.height;
    bool wasLandscape = oldRotation % 180 == 0;
    bool isLandscape = newRotation % 180 == 0;
    if (wasLandscape != isLandscape) {
      newWidth = oldMonitor.height;
      newHeight = oldMonitor.width;
    }
    double minX = mons.map((m) => m.x).reduce(min);
    double minY = mons.map((m) => m.y).reduce(min);
    double newAbsX = minX + (updatedTile.x - _offsetX) / _scaleFactor;
    double newAbsY = minY + (updatedTile.y - _offsetY) / _scaleFactor;
    final newOrientation = newRotation % 180 == 0 ? 'landscape' : 'portrait';
    final newAbsMonitor = MonitorTileData(
      id: oldMonitor.id,
      manufacturer: oldMonitor.manufacturer,
      x: newAbsX,
      y: newAbsY,
      width: newWidth,
      height: newHeight,
      scale: oldMonitor.scale,
      rotation: newRotation,
      refresh: oldMonitor.refresh,
      resolution: newOrientation == 'landscape'
          ? '${newWidth.toInt()}x${newHeight.toInt()}'
          : '${newHeight.toInt()}x${newWidth.toInt()}',
      orientation: newOrientation,
      modes: oldMonitor.modes,
      enabled: oldMonitor.enabled,
    );
    setState(() {
      profiles[activeProfileIndex!].monitors[index] = newAbsMonitor;
      _buildAndSave(constraints);
    });
  }

  void _onMonitorDragStart(MonitorTileData tile) {
    if (activeProfileIndex == null) return;
    final index = activeMonitors.indexWhere((m) => m.id == tile.id);
    if (index == -1) return;
    if (!activeMonitors[index].enabled) return;
    _oldPositionsBeforeDrag[tile.id] = activeMonitors[index];
  }

  void _onMonitorDragEnd(MonitorTileData tile, BoxConstraints constraints) {
    if (activeProfileIndex == null) return;
    final mons = [...activeMonitors];
    final index = mons.indexWhere((m) => m.id == tile.id);
    if (index == -1) return;
    if (!mons[index].enabled) return;
    final snapped = _snapToEdges(mons[index], mons);
    mons[index] = snapped;
    if (_hasOverlap(snapped, mons, index)) {
      final old = _oldPositionsBeforeDrag[tile.id];
      if (old != null) mons[index] = old;
    }
    setState(() {
      profiles[activeProfileIndex!] = Profile(
        name: profiles[activeProfileIndex!].name,
        monitors: mons,
      );
      _oldPositionsBeforeDrag.remove(tile.id);
      _buildAndSave(constraints);
    });
  }

  void _onMonitorScale(String id, double newScale, BoxConstraints constraints) {
    if (activeProfileIndex == null) return;
    final mons = activeMonitors;
    for (int n = 1; n <= 8; n++) {
      if ((newScale - n).abs() < 0.05) {
        newScale = n.toDouble();
        break;
      }
    }
    newScale = double.parse(newScale.toStringAsFixed(2));
    final index = mons.indexWhere((m) => m.id == id);
    if (index == -1) return;
    if (!mons[index].enabled) return;
    final updated = mons[index].copyWith(scale: newScale);

    // Neighbour adjustment
    for (int i = 0; i < mons.length; i++) {
      if (i == index) continue;
      var other = mons[i];
      if ((other.x - (mons[index].x + mons[index].width / mons[index].scale))
              .abs() <= snapThreshold) {
        other = other.copyWith(x: mons[index].x + mons[index].width / newScale);
      } else if (((other.x + other.width / other.scale) - mons[index].x)
              .abs() <= snapThreshold) {
        other =
            other.copyWith(x: mons[index].x - other.width / other.scale);
      }
      if ((other.y - (mons[index].y + mons[index].height / mons[index].scale))
              .abs() <= snapThreshold) {
        other = other.copyWith(y: mons[index].y + mons[index].height / newScale);
      } else if (((other.y + other.height / other.scale) - mons[index].y)
              .abs() <= snapThreshold) {
        other =
            other.copyWith(y: mons[index].y - other.height / other.scale);
      }
      mons[i] = other;
    }

    mons[index] = updated;
    setState(() {
      profiles[activeProfileIndex!] =
          Profile(name: profiles[activeProfileIndex!].name, monitors: mons);
      _buildAndSave(constraints);
    });
  }

  Future<void> _onMonitorModeChange(
      String id, MonitorMode mode, BoxConstraints constraints) async {
    if (activeProfileIndex == null) return;
    final mons = activeMonitors;
    final index = mons.indexWhere((m) => m.id == id);
    if (index == -1) return;

    if (mons[index].enabled) {
      final target = _resolveOutputName(id);
      try {
        final result = await Process.run('/usr/bin/swaymsg', [
          'output',
          target,
          'mode',
          '${mode.width.toInt()}x${mode.height.toInt()}@${_formatHz(mode.refresh)}Hz'
        ]);
        if (result.exitCode != 0) {
          debugPrint('Error setting mode: ${result.stderr}');
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Failed to set mode: ${result.stderr}')),
            );
          }
          return;
        }
      } catch (e) {
        debugPrint('Error setting mode: $e');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error setting mode: $e')),
          );
        }
        return;
      }
      // Nach erfolgreichem Setzen State nachziehen
      await _updateConnectedMonitors();
    }

    final rotatedWidth =
        (mons[index].rotation % 180 == 0) ? mode.width : mode.height;
    final rotatedHeight =
        (mons[index].rotation % 180 == 0) ? mode.height : mode.width;
    final updated = mons[index].copyWith(
      width: rotatedWidth,
      height: rotatedHeight,
      refresh: mode.refresh,
      resolution: '${rotatedWidth.toInt()}x${rotatedHeight.toInt()}',
      orientation: (mons[index].rotation % 180 == 0)
          ? (mode.width >= mode.height ? 'landscape' : 'portrait')
          : (mode.width >= mode.height ? 'portrait' : 'landscape'),
    );
    mons[index] = updated;
    setState(() {
      profiles[activeProfileIndex!] =
          Profile(name: profiles[activeProfileIndex!].name, monitors: mons);
      _buildAndSave(constraints);
    });
  }

  Future<void> _onMonitorToggleEnabled(
      String id, bool enabled, BoxConstraints constraints) async {
    if (activeProfileIndex == null) return;
    final mons = activeMonitors;
    final index = mons.indexWhere((m) => m.id == id);
    if (index == -1) return;

    try {
      final target = _resolveOutputName(id);
      // Stelle sicher, dass der Output laut Sway existiert.
      final currentOutput = _currentModeForOutput(target);
      if (currentOutput == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Output $target not found.')),
          );
        }
        return;
      }

      if (!enabled) {
        final result = await Process.run(
          '/usr/bin/swaymsg',
          ['output', target, 'disable'],
        );
        if (result.exitCode != 0) {
          debugPrint('Error toggling output: ${result.stderr}');
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                  content:
                      Text('Could not toggle output $target: ${result.stderr}')),
            );
          }
          return;
        }
      } else {
        // Beim Aktivieren: erst enable, dann (falls möglich) Mode/Scale/Transform/Position setzen.
        final monitor = mons[index];
        final mode = _bestModeForWithFallback(
          monitor,
          monitor.modes,
        );
        final transform = switch (monitor.rotation % 360) {
          90 => '90',
          180 => '180',
          270 => '270',
          _ => 'normal',
        };
        final posX = monitor.x.toInt();
        final posY = monitor.y.toInt();

        // Zuerst nur enable
        var result = await Process.run('/usr/bin/swaymsg', [
          'output',
          target,
          'enable',
        ]);
        if (result.exitCode != 0) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                  content:
                      Text('Could not enable output $target: ${result.stderr}')),
            );
          }
          return;
        }

        // Dann Konfiguration, falls Mode vorhanden
        if (mode != null) {
          result = await Process.run('/usr/bin/swaymsg', [
            'output',
            target,
            'scale',
            monitor.scale.toStringAsFixed(2),
            'mode',
            '${mode.width.toInt()}x${mode.height.toInt()}@${_formatHz(mode.refresh)}Hz',
            'transform',
            transform,
            'position',
            '$posX,$posY',
          ]);
          if (result.exitCode != 0 && mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                  content: Text(
                      'Enabled, but failed to set mode: ${result.stderr}')),
            );
          }
        }
      }
    } catch (e) {
      debugPrint('Error toggling output: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error while toggling: $e')),
        );
      }
      return;
    }

    await _updateConnectedMonitors();
    if (!mounted) return;

    // Nur bei Erfolg den lokalen Zustand dauerhaft setzen, sonst zurückrollen.
    final current = currentMonitors.any((m) =>
        _normalizeOutputId(m.id) == _normalizeOutputId(_resolveOutputName(id)) &&
        m.enabled == enabled);
    if (current) {
      setState(() {
        mons[index] = mons[index].copyWith(enabled: enabled);
        profiles[activeProfileIndex!] =
            Profile(name: profiles[activeProfileIndex!].name, monitors: mons);
        _buildAndSave(constraints);
      });
      if (enabled) {
        _maybeWarnBandwidth(mons);
      }
      await _waitForOutputState(_resolveOutputName(id), shouldExist: enabled);
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Output ${enabled ? 'not enabled' : 'not disabled'} - status unchanged.")),
        );
      }
    }
  }

  MonitorMode _bestModeFor(MonitorTileData monitor) {
    if (monitor.modes.isEmpty) {
      return MonitorMode(
        width: monitor.width,
        height: monitor.height,
        refresh: monitor.refresh > 0 ? monitor.refresh : 60,
      );
    }
    final modes = [...monitor.modes]
      ..sort((a, b) {
        final areaA = a.width * a.height;
        final areaB = b.width * b.height;
        if (areaA != areaB) return areaB.compareTo(areaA);
        return b.refresh.compareTo(a.refresh);
      });
    return modes.first;
  }

  MonitorMode? _bestModeForWithFallback(
      MonitorTileData monitor, List<MonitorMode> modes) {
    if (modes.isEmpty) {
      return MonitorMode(
        width: monitor.width,
        height: monitor.height,
        refresh: monitor.refresh > 0 ? monitor.refresh : 60,
      );
    }
    final sorted = [...modes]
      ..sort((a, b) {
        final areaA = a.width * a.height;
        final areaB = b.width * b.height;
        if (areaA != areaB) return areaB.compareTo(areaA);
        return b.refresh.compareTo(a.refresh);
      });
    return sorted.first;
  }

  Future<void> _promptCustomMode(
      String id, BoxConstraints constraints) async {
    final current = _currentModeForOutput(id);
    final widthController = TextEditingController(
        text: current != null ? current.width.toInt().toString() : '1920');
    final heightController = TextEditingController(
        text: current != null ? current.height.toInt().toString() : '1080');
    final refreshController = TextEditingController(
        text: current != null ? _formatHz(current.refresh) : '60');

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Custom Mode (Advanced)'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: widthController,
                decoration: const InputDecoration(labelText: 'Width (px)'),
                keyboardType: TextInputType.number,
              ),
              TextField(
                controller: heightController,
                decoration: const InputDecoration(labelText: 'Height (px)'),
                keyboardType: TextInputType.number,
              ),
              TextField(
                controller: refreshController,
                decoration: const InputDecoration(labelText: 'Hz'),
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
              ),
              const SizedBox(height: 8),
              const Text(
                'Warning: custom modes can fail. You can revert afterwards via "Revert last custom mode".',
                style: TextStyle(fontSize: 12),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Apply'),
            ),
          ],
        );
      },
    );

    if (confirmed != true) return;

    final w = double.tryParse(widthController.text.trim());
    final h = double.tryParse(heightController.text.trim());
    final hz = double.tryParse(refreshController.text.trim());
    if (w == null || h == null || hz == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Invalid input for custom mode.')),
        );
      }
      return;
    }
    await _applyCustomMode(id, w, h, hz, constraints);
  }

  Future<void> _applyCustomMode(String id, double w, double h, double hz,
      BoxConstraints constraints) async {
    final target = _resolveOutputName(id);
    final current = _currentModeForOutput(target);
    if (current != null) {
      _lastModeBeforeCustom[target] = current;
    }

    bool applied = false;
    String? error;
    final cmdRandr = File('/usr/bin/wlr-randr');

    try {
      ProcessResult result;
      if (cmdRandr.existsSync()) {
        result = await Process.run(cmdRandr.path, [
          '--output',
          target,
          '--mode',
          '${w.toInt()}x${h.toInt()}@${_formatHz(hz)}'
        ]);
      } else {
        result = await Process.run('/usr/bin/swaymsg', [
          'output',
          target,
          'mode',
          '${w.toInt()}x${h.toInt()}@${_formatHz(hz)}Hz'
        ]);
      }
      if (result.exitCode == 0) {
        applied = true;
      } else {
        error = '${result.stderr}'.trim();
      }
    } catch (e) {
      error = '$e';
    }

    await _updateConnectedMonitors();

    if (!applied) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Custom mode failed: ${error ?? 'unknown error'}',
            ),
          ),
        );
      }
      return;
    }

    // UI/Profil updaten
    if (activeProfileIndex != null) {
      final mons = activeMonitors;
      final idx = mons.indexWhere(
          (m) => _normalizeOutputId(m.id) == _normalizeOutputId(target));
      if (idx != -1) {
        final rotation = mons[idx].rotation;
        final rotatedW = rotation % 180 == 0 ? w : h;
        final rotatedH = rotation % 180 == 0 ? h : w;
        final updated = mons[idx].copyWith(
          width: rotatedW,
          height: rotatedH,
          refresh: hz,
          resolution: '${rotatedW.toInt()}x${rotatedH.toInt()}',
          orientation: rotation % 180 == 0
              ? (w >= h ? 'landscape' : 'portrait')
              : (w >= h ? 'portrait' : 'landscape'),
        );
        mons[idx] = updated;
        setState(() {
          profiles[activeProfileIndex!] =
              Profile(name: profiles[activeProfileIndex!].name, monitors: mons);
          _buildAndSave(constraints);
        });
        _maybeWarnBandwidth(mons);
      }
    }

    final modeLabel = '${w.toInt()}x${h.toInt()}@${_formatHz(hz)}Hz';
    _scheduleCustomRevert(target, modeLabel, constraints);

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Applied custom mode: $modeLabel on $target'),
          action: SnackBarAction(
            label: 'Keep',
            onPressed: () => _cancelCustomRevert(target),
          ),
        ),
      );
    }
  }

  Future<void> _revertCustomMode(
      String id, BoxConstraints constraints) async {
    final target = _resolveOutputName(id);
    final last = _lastModeBeforeCustom[target];
    if (last == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No saved custom mode to revert.')),
        );
      }
      return;
    }
    await _onMonitorModeChange(id, last, constraints);
    _lastModeBeforeCustom.remove(target);
    _cancelCustomRevert(target);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Custom mode reverted.')),
      );
    }
  }

  void _scheduleCustomRevert(
      String target, String label, BoxConstraints constraints) {
    _cancelCustomRevert(target);
    _customModeRevertTimers[target] = Timer(
      const Duration(seconds: 10),
      () => _revertCustomMode(target, constraints),
    );
  }

  void _cancelCustomRevert(String target) {
    _customModeRevertTimers[target]?.cancel();
    _customModeRevertTimers.remove(target);
  }

  MonitorTileData _snapToEdges(MonitorTileData m, List<MonitorTileData> all) {
    double newX = m.x;
    double newY = m.y;
    for (var other in all) {
      if (other.id == m.id) continue;
      final left = m.x;
      final right = m.x + m.width / m.scale;
      final top = m.y;
      final bottom = m.y + m.height / m.scale;
      final oLeft = other.x;
      final oRight = other.x + other.width / other.scale;
      final oTop = other.y;
      final oBottom = other.y + other.height / other.scale;
      if ((left - oRight).abs() <= snapThreshold) newX = oRight;
      if ((right - oLeft).abs() <= snapThreshold)
        newX = oLeft - m.width / m.scale;
      if ((top - oBottom).abs() <= snapThreshold) newY = oBottom;
      if ((bottom - oTop).abs() <= snapThreshold)
        newY = oTop - m.height / m.scale;
    }
    return m.copyWith(x: newX, y: newY);
  }

  bool _hasOverlap(
      MonitorTileData updated, List<MonitorTileData> all, int idx) {
    final a = Rect.fromLTWH(
        updated.x,
        updated.y,
        updated.width / updated.scale,
        updated.height / updated.scale);
    for (int i = 0; i < all.length; i++) {
      if (i == idx) continue;
      final o = all[i];
      final b = Rect.fromLTWH(
          o.x, o.y, o.width / o.scale, o.height / o.scale);
      if (a.overlaps(b)) return true;
    }
    return false;
  }

  int? _findProfileWithAllCurrentMonitors() {
    final currentEnabled =
        currentMonitors.where((m) => m.enabled).toList();
    for (int i = 0; i < profiles.length; i++) {
      final p = profiles[i];
      final enabledMonitors =
          p.monitors.where((m) => m.enabled).toList();
      if (enabledMonitors.length != currentEnabled.length) continue;
      bool allMatch = true;
      for (var cm in currentEnabled) {
        if (!enabledMonitors.any((pm) => _monitorsMatch(pm, cm))) {
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
    final m = currentMonitors
        .where((o) => _normalizeOutputId(o.id) == norm)
        .toList();
    if (m.isEmpty) return null;
    return MonitorMode(
      width: m.first.width,
      height: m.first.height,
      refresh: m.first.refresh,
    );
  }

  double _totalPixelRate(List<MonitorTileData> mons) {
    double sum = 0;
    for (final m in mons.where((m) => m.enabled)) {
      sum += m.width * m.height * (m.refresh > 0 ? m.refresh : 60);
    }
    return sum;
  }

  void _maybeWarnBandwidth(List<MonitorTileData> mons) {
    // Grober Schwellenwert; anpassbar falls nötig.
    const double threshold = 700000000; // Pixel*Hz
    if (_totalPixelRate(mons) > threshold && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
              'High total load (pixels*Hz). A monitor might stay black - try lowering refresh/resolution.'),
        ),
      );
    }
  }

  void _createCurrentSetup() {
    final newProfile = Profile(
      name: 'Current Setup',
      monitors: currentMonitors.map((m) {
        return m.rotation % 180 == 0
            ? m.copyWith(orientation: 'landscape')
            : m.copyWith(
                width: m.height,
                height: m.width,
                orientation: 'portrait',
              );
      }).toList(),
    );
    setState(() {
      profiles.add(newProfile);
      activeProfileIndex = profiles.length - 1;
    });
    _autoSave();
  }

  void _buildAndSave(BoxConstraints constraints) {
    _updateDisplayMonitors(constraints);
    _autoSave();
  }

  void _toggleSidebar() {
    setState(() {
      _isSidebarOpen = !_isSidebarOpen;
      if (_isSidebarOpen) {
        _iconController.forward();
      } else {
        _iconController.reverse();
      }
    });
  }

  void _restartKanshi() async {
    try {
      final result = await Process.run('bash', [
        '-c',
        'pkill -x kanshi; sleep 0.2; setsid /usr/bin/kanshi -c ~/.config/kanshi/config >/tmp/kanshi_gui.log 2>&1 &'
      ]);

      if (result.exitCode != 0) {
        debugPrint('Error running kanshi: ${result.stderr}');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: ${result.stderr}')),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('kanshi has been (re)started.')),
        );
      }
    } catch (e) {
      debugPrint('Exception while starting kanshi: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Exception: $e')),
      );
    }
  }

  Future<void> _reloadData() async {
    try {
      await _updateConnectedMonitors();
      await _loadConfig();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Outputs and profiles refreshed.')),
        );
      }
    } catch (e) {
      debugPrint('Reload failed: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Reload failed: $e')),
        );
      }
    }
  }

  Future<void> _reloadAndApply() async {
    try {
      await _configService.saveProfiles(profiles);
      final result = await Process.run('bash', [
        '-c',
        'pkill -x kanshi; sleep 0.2; setsid /usr/bin/kanshi -c ~/.config/kanshi/config >/tmp/kanshi_gui.log 2>&1 &'
      ]);
      if (result.exitCode != 0) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('kanshi restart failed: ${result.stderr}')),
          );
        }
      } else {
        await _reloadData();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Reloaded and restarted kanshi.')),
          );
        }
      }
    } catch (e) {
      debugPrint('reload/apply failed: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Reload failed: $e')),
        );
      }
    }
  }

  Future<void> _saveProfilesOnly() async {
    try {
      await _configService.saveProfiles(profiles);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Profiles saved.')),
        );
      }
    } catch (e) {
      debugPrint('saveProfiles failed: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Save failed: $e')),
        );
      }
    }
  }

  Future<void> _restoreBackupAndApply() async {
    try {
      final backup = File(_configService.backupPath);
      if (!await backup.exists()) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('No backup found.')),
          );
        }
        return;
      }
      await backup.copy(_configService.configPath);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Backup restored.')),
        );
      }
      await _reloadAndApply();
    } catch (e) {
      debugPrint('restore/apply failed: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Backup restore failed: $e')),
        );
      }
    }
  }

  Future<void> _showKanshiLog() async {
    final logFile = File('/tmp/kanshi_gui.log');
    String content;
    if (await logFile.exists()) {
      content = await logFile.readAsString();
      if (content.length > 6000) {
        content = content.substring(content.length - 6000);
      }
    } else {
      content = 'Log file /tmp/kanshi_gui.log does not exist.';
    }
    if (!mounted) return;
    // ignore: use_build_context_synchronously
    await showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('kanshi GUI Log'),
          content: SizedBox(
            width: 600,
            height: 400,
            child: SingleChildScrollView(
              child: Text(
                content,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _showHelpDialog() async {
    if (!mounted) return;
    await showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Tips'),
          content: const Text(
            'Tips:\n- Monitor menu: set resolution/Hz directly or test a custom mode (auto-revert after 10s unless you click "Keep").\n- Reload button at the top: save and restart kanshi.\n- Watch the bandwidth warning if many pixels/Hz are active.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _handleNativeMenuSelect(MethodCall call) async {
    if (call.method != 'select') return;
    final action = call.arguments as String?;
    switch (action) {
      case 'saveRestart':
        await _reloadAndApply();
        break;
      case 'saveProfiles':
        await _saveProfilesOnly();
        break;
      case 'reload':
        await _reloadData();
        break;
      case 'enableAll':
        await _enableAllOutputs();
        break;
      case 'restartKanshi':
        _restartKanshi();
        break;
      case 'restoreBackup':
        await _restoreBackupAndApply();
        break;
      case 'showLogs':
        await _showKanshiLog();
        break;
      case 'showHelp':
        await _showHelpDialog();
        break;
      default:
        break;
    }
  }

  List<PlatformMenuItem> _buildPlatformMenus() {
    return [
      PlatformMenu(
        label: 'File',
        menus: [
          PlatformMenuItem(
            label: 'Save & restart kanshi',
            onSelected: () => _reloadAndApply(),
          ),
          PlatformMenuItem(
            label: 'Save profiles only',
            onSelected: () => _saveProfilesOnly(),
          ),
          PlatformMenuItem(
            label: 'Reload outputs & profiles',
            onSelected: () => _reloadData(),
          ),
        ],
      ),
      PlatformMenu(
        label: 'Actions',
        menus: [
          PlatformMenuItem(
            label: 'Enable all displays',
            onSelected: () => _enableAllOutputs(),
          ),
          PlatformMenuItem(
            label: 'Restart kanshi',
            onSelected: () => _restartKanshi(),
          ),
          PlatformMenuItem(
            label: 'Restore backup & apply',
            onSelected: () => _restoreBackupAndApply(),
          ),
          PlatformMenuItem(
            label: 'Show logs',
            onSelected: () => _showKanshiLog(),
          ),
        ],
      ),
      PlatformMenu(
        label: 'Help',
        menus: [
          PlatformMenuItem(
            label: 'Show tips',
            onSelected: () => _showHelpDialog(),
          ),
        ],
      ),
    ];
  }

  String _formatHz(double hz) {
    final isInt = (hz - hz.round()).abs() < 0.01;
    return isInt ? hz.round().toString() : hz.toStringAsFixed(3);
  }


  @override
  Widget build(BuildContext context) {
    return PlatformMenuBar(
      menus: _buildPlatformMenus(),
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            icon: AnimatedIcon(
              icon: AnimatedIcons.menu_close,
              progress: _iconController,
            ),
            tooltip: 'Toggle Sidebar',
            onPressed: _toggleSidebar,
          ),
          title: const Text('Kanshi GUI'),
          actions: [
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: 'Reload & restart kanshi',
              onPressed: _reloadAndApply,
            ),
          ],
        ),
        body: Stack(
          children: [
            AnimatedPositioned(
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeInOut,
              left: _isSidebarOpen ? 320 : 0,
              top: 0,
              right: 0,
              bottom: 0,
              child: Container(
                color: Colors.black,
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    _updateDisplayMonitors(constraints);
                    return Stack(
                      children: _displayMonitors.map((tile) {
                        final original =
                            activeMonitors.firstWhere((m) => m.id == tile.id);
                        return MonitorTile(
                          key: ValueKey(tile.id),
                          data: tile,
                          exists: currentMonitors
                              .any((m) => _matchesOutput(m.id, tile.id)),
                          snapThreshold: snapThreshold,
                          containerSize: Size(
                              constraints.maxWidth, constraints.maxHeight),
                          scaleFactor: _scaleFactor,
                          offsetX: _offsetX,
                          offsetY: _offsetY,
                          originX: 0,
                          originY: 0,
                          originalWidth: original.width,
                          originalHeight: original.height,
                          onDragStart: () => _onMonitorDragStart(tile),
                          onUpdate: (updated) =>
                              _onMonitorUpdate(updated, constraints),
                          onDragEnd: () =>
                              _onMonitorDragEnd(tile, constraints),
                          onScale: (s) =>
                              _onMonitorScale(tile.id, s, constraints),
                          onModeChange: (m) =>
                              _onMonitorModeChange(tile.id, m, constraints),
                          onToggleEnabled: (enabled) =>
                              _onMonitorToggleEnabled(
                                  tile.id, enabled, constraints),
                          onCustomMode: () =>
                              _promptCustomMode(tile.id, constraints),
                          onCustomModeRevert: () =>
                              _revertCustomMode(tile.id, constraints),
                        );
                      }).toList(),
                    );
                  },
                ),
              ),
            ),
            AnimatedPositioned(
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeInOut,
              left: _isSidebarOpen ? 0 : -320,
              top: 0,
              bottom: 0,
              width: 320,
              child: Container(
                color: Colors.grey[850],
                child: Column(
                  children: [
                    Expanded(
                      child: ListView.builder(
                        itemCount: profiles.length,
                        itemBuilder: (context, i) {
                          return ProfileListItem(
                            profile: profiles[i],
                            isActive: activeProfileIndex == i,
                            onSelect: () =>
                                setState(() => activeProfileIndex = i),
                            onNameChanged: (newName) {
                              final exists = profiles.any((p) =>
                                  p.name.toLowerCase() ==
                                      newName.toLowerCase() &&
                                  p != profiles[i]);
                              if (exists) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                      content: Text(
                                          'Profile name already exists!')),
                                );
                              } else {
                                setState(() {
                                  profiles[i].name = newName;
                                  _autoSave();
                                });
                              }
                            },
                            onDelete: () {
                              setState(() {
                                if (activeProfileIndex == i) {
                                  activeProfileIndex = null;
                                }
                                profiles.removeAt(i);
                                _autoSave();
                              });
                            },
                            exists: true,
                          );
                        },
                      ),
                    ),
                    if (_findProfileWithAllCurrentMonitors() == null)
                      Padding(
                        padding: const EdgeInsets.all(8.0),
                        child: ElevatedButton(
                          onPressed: _createCurrentSetup,
                          child: const Text('Create Current Setup'),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
