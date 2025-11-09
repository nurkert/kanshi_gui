import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
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

enum _SidebarSection { profiles, repair, help }

class _HomePageState extends State<HomePage> with SingleTickerProviderStateMixin {
  final ConfigService _configService = ConfigService();

  /// Geladene Profile aus der Konfiguration.
  List<Profile> profiles = [];

  /// Aktuell verbundene Monitore.
  List<MonitorTileData> currentMonitors = [];

  /// Controller für das Menü‑Icon.
  late final AnimationController _iconController;

  @override
  void initState() {
    super.initState();
    _iconController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    _initSetup();
  }

  @override
  void dispose() {
    _iconController.dispose();
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
      final modeMaps = (output['modes'] as List).cast<Map<String, dynamic>>();
      final modes = modeMaps
          .map((m) => MonitorMode(
                width: (m['width'] as num).toDouble(),
                height: (m['height'] as num).toDouble(),
                refresh: ((m['refresh'] as num).toInt() / 1000).round(),
              ))
          .toList();
      Map<String, dynamic> best = modeMaps.reduce((a, b) {
        int aPx = a['width'] * a['height'];
        int bPx = b['width'] * b['height'];
        if (aPx != bPx) return aPx > bPx ? a : b;
        return (a['refresh'] > b['refresh']) ? a : b;
      });
      double width = (best['width'] as num).toDouble();
      double height = (best['height'] as num).toDouble();
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
        id: fullName,
        manufacturer: fullName,
        x: (output['rect']['x'] as num).toDouble(),
        y: (output['rect']['y'] as num).toDouble(),
        width: width,
        height: height,
        scale: scale,
        rotation: rotation,
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
  _SidebarSection _sidebarSection = _SidebarSection.profiles;
  bool _isEnablingOutputs = false;

  String _normalizeOutputId(String value) {
    return value.replaceAll(RegExp(r'\s+'), ' ').trim().toLowerCase();
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

        try {
          final enableResult =
              await Process.run('swaymsg', ['output', fullName, 'enable']);
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
        message = 'Keine Ausgänge gefunden.';
      } else if (failures.isEmpty) {
        message =
            'Alle ${outputs.length} Ausgänge wurden erfolgreich aktiviert.';
      } else {
        message =
            'Aktiviert: $successCount/${outputs.length}. Fehler: ${failures.join(', ')}';
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
          SnackBar(content: Text('Ausgänge konnten nicht aktiviert werden: $e')),
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
              (m) =>
                  _matchesOutput(m.manufacturer, profile.monitors[i].manufacturer),
              orElse: () => profile.monitors[i],
            );
            profile.monitors[i] =
                profile.monitors[i].copyWith(modes: connected.modes);
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
      try {
        await Process.run('swaymsg', [
          'output',
          id,
          'mode',
          '${mode.width.toInt()}x${mode.height.toInt()}@${mode.refresh}Hz'
        ]);
      } catch (e) {
        debugPrint('Error setting mode: $e');
      }
    }

    final rotatedWidth =
        (mons[index].rotation % 180 == 0) ? mode.width : mode.height;
    final rotatedHeight =
        (mons[index].rotation % 180 == 0) ? mode.height : mode.width;
    final updated = mons[index].copyWith(
      width: rotatedWidth,
      height: rotatedHeight,
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

    setState(() {
      mons[index] = mons[index].copyWith(enabled: enabled);
      profiles[activeProfileIndex!] =
          Profile(name: profiles[activeProfileIndex!].name, monitors: mons);
      _buildAndSave(constraints);
    });

    try {
      final result = await Process.run(
        'swaymsg',
        ['output', id, enabled ? 'enable' : 'disable'],
      );
      if (result.exitCode != 0) {
        debugPrint('Error toggling output: ${result.stderr}');
      }
    } catch (e) {
      debugPrint('Error toggling output: $e');
    }

    await _updateConnectedMonitors();
    if (!mounted) return;
    await _waitForOutputState(id, shouldExist: enabled);
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
        if (!enabledMonitors.any(
            (pm) => _matchesOutput(pm.manufacturer, cm.manufacturer))) {
          allMatch = false;
          break;
        }
      }
      if (allMatch) return i;
    }
    return null;
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
      final result = await Process.run(
        'bash',
        ['-c', '[ ! "\$(pgrep kanshi)" ] && pkill kanshi; kanshi &'],
      );

      if (result.exitCode != 0) {
        debugPrint('Fehler beim Ausführen von kanshi: ${result.stderr}');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Fehler: ${result.stderr}')),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('kanshi wurde (neu) gestartet.')),
        );
      }
    } catch (e) {
      debugPrint('Exception beim Starten von kanshi: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Exception: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
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
            tooltip: 'Restart kanshi',
            onPressed: _restartKanshi,
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
                      final original = activeMonitors
                          .firstWhere((m) => m.id == tile.id);
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
                        onDragEnd: () => _onMonitorDragEnd(tile, constraints),
                        onScale: (s) => _onMonitorScale(tile.id, s, constraints),
                        onModeChange: (m) =>
                            _onMonitorModeChange(tile.id, m, constraints),
                        onToggleEnabled: (enabled) =>
                            _onMonitorToggleEnabled(
                                tile.id, enabled, constraints),
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
                  Padding(
                    padding: const EdgeInsets.all(8.0),
                    child: SegmentedButton<_SidebarSection>(
                      segments: const [
                        ButtonSegment<_SidebarSection>(
                          value: _SidebarSection.profiles,
                          label: Text('Profiles'),
                          icon: Icon(Icons.person),
                        ),
                        ButtonSegment<_SidebarSection>(
                          value: _SidebarSection.repair,
                          label: Text('Repair'),
                          icon: Icon(Icons.build),
                        ),
                        ButtonSegment<_SidebarSection>(
                          value: _SidebarSection.help,
                          label: Text('Help'),
                          icon: Icon(Icons.help_outline),
                        ),
                      ],
                      selected: <_SidebarSection>{_sidebarSection},
                      onSelectionChanged: (newSelection) {
                        setState(() {
                          _sidebarSection = newSelection.first;
                        });
                      },
                    ),
                  ),
                  if (_sidebarSection == _SidebarSection.profiles) ...[
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
                              bool exists = profiles.any((p) =>
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
                                if (activeProfileIndex == i)
                                  activeProfileIndex = null;
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
                  ] else if (_sidebarSection == _SidebarSection.repair) ...[
                    Expanded(
                      child: ListView(
                        padding: const EdgeInsets.symmetric(horizontal: 8.0),
                        children: const [
                          ListTile(
                            leading: Icon(Icons.restart_alt),
                            title: Text('Restart kanshi'),
                            subtitle: Text(
                                'Run repair actions for kanshi configuration.'),
                          ),
                          ListTile(
                            leading: Icon(Icons.cleaning_services),
                            title: Text('Clean temporary files'),
                            subtitle: Text(
                                'Placeholder for future repair utilities.'),
                          ),
                        ],
                      ),
                    ),
                  ] else ...[
                    Expanded(
                      child: ListView(
                        padding: const EdgeInsets.symmetric(horizontal: 8.0),
                        children: [
                          ListTile(
                            leading: const Icon(Icons.monitor_heart),
                            title: const Text('Alle Ausgänge aktivieren'),
                            subtitle: const Text(
                                'Aktiviert alle bekannten Monitore mittels swaymsg.'),
                            enabled: !_isEnablingOutputs,
                            onTap:
                                _isEnablingOutputs ? null : () => _enableAllOutputs(),
                            trailing: _isEnablingOutputs
                                ? const SizedBox(
                                    height: 24,
                                    width: 24,
                                    child: CircularProgressIndicator(),
                                  )
                                : FilledButton(
                                    onPressed: () => _enableAllOutputs(),
                                    child: const Text('Aktivieren'),
                                  ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
