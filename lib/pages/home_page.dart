import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:kanshi_gui/models/monitor_tile_data.dart';
import 'package:kanshi_gui/models/profiles.dart';
import 'package:kanshi_gui/services/config_service.dart';
import 'package:kanshi_gui/widgets/monitor_tile.dart';
import 'package:kanshi_gui/widgets/profile_list_item.dart';

class HomePage extends StatefulWidget {
  const HomePage({Key? key}) : super(key: key);

  @override
  _HomePageState createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with SingleTickerProviderStateMixin {
  final ConfigService _configService = ConfigService();

  /// Loaded profiles from config.
  List<Profile> profiles = [];

  /// List of currently connected monitors.
  List<MonitorTileData> currentMonitors = [];

  /// Controller for menu ↔ close icon animation.
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
      if (output['active'] != true) continue;
      final make = (output['make'] ?? 'Unknown').toString().trim();
      final model = (output['model'] ?? 'Unknown').toString().trim();
      final serial = (output['serial'] ?? 'Unknown').toString().trim();
      String fullName = '$make $model $serial'
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      final modes = (output['modes'] as List).cast<Map<String, dynamic>>();
      Map<String, dynamic> best = modes.reduce((a, b) {
        int aPx = a['width'] * a['height'];
        int bPx = b['width'] * b['height'];
        if (aPx != bPx) return aPx > bPx ? a : b;
        return (a['refresh'] > b['refresh']) ? a : b;
      });
      double width = (best['width'] as num).toDouble();
      double height = (best['height'] as num).toDouble();
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
        rotation: rotation,
        resolution: '${width.toInt()}x${height.toInt()}',
        orientation: orientation,
      ));
    }
    return monitors;
  }

  Future<void> ensureCurrentSetupMatchesConnectedMonitors() async {
    List<MonitorTileData> connected = await getConnectedMonitors();
    Set<String> normalize(List<MonitorTileData> list) =>
        list.map((m) => m.manufacturer.trim()).toSet();
    Set<String> connectedIds = normalize(connected);
    int index = profiles.indexWhere((p) => p.name == 'Current Setup');
    if (index == -1) {
      Profile currentSetup = Profile(name: 'Current Setup', monitors: connected);
      setState(() {
        profiles.add(currentSetup);
        activeProfileIndex = profiles.length - 1;
      });
    } else {
      Profile currentSetup = profiles[index];
      Set<String> currentIds = normalize(currentSetup.monitors);
      if (currentIds.difference(connectedIds).isNotEmpty ||
          connectedIds.difference(currentIds).isNotEmpty) {
        setState(() {
          profiles[index] =
              Profile(name: 'Current Setup', monitors: connected);
          activeProfileIndex = index;
        });
      }
    }
    final home = Platform.environment['HOME'] ?? '/home/nburkert';
    final file = File('$home/.config/kanshi/current');
    await file.create(recursive: true);
    await file.writeAsString('Current Setup');
    _autoSave();
  }

  int? activeProfileIndex;
  bool _isSidebarOpen = false;
  final double snapThreshold = 500.0;
  double _scaleFactor = 1.0;
  double _offsetX = 0;
  double _offsetY = 0;
  List<MonitorTileData> _displayMonitors = [];
  Map<String, MonitorTileData> _oldPositionsBeforeDrag = {};
  Timer? _saveTimer;

  List<MonitorTileData> get activeMonitors {
    if (activeProfileIndex == null) return [];
    return profiles[activeProfileIndex!].monitors;
  }

  Future<void> _updateConnectedMonitors() async {
    try {
      List<MonitorTileData> monitors = await getConnectedMonitors();
      setState(() => currentMonitors = monitors);
    } catch (e) {
      debugPrint('Error getting connected monitors: $e');
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
    double minX = mons.map((m) => m.x).reduce(min);
    double minY = mons.map((m) => m.y).reduce(min);
    double maxX = mons.map((m) => m.x + m.width).reduce(max);
    double maxY = mons.map((m) => m.y + m.height).reduce(max);
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
      double dw = m.width * _scaleFactor;
      double dh = m.height * _scaleFactor;
      return m.copyWith(x: dx, y: dy, width: dw, height: dh);
    }).toList();
  }

  void _onMonitorUpdate(MonitorTileData updatedTile, BoxConstraints constraints) {
    if (activeProfileIndex == null) return;
    final mons = activeMonitors;
    final index = mons.indexWhere((m) => m.id == updatedTile.id);
    if (index == -1) return;
    final oldMonitor = mons[index];
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
      rotation: newRotation,
      resolution: newOrientation == 'landscape'
          ? '${newWidth.toInt()}x${newHeight.toInt()}'
          : '${newHeight.toInt()}x${newWidth.toInt()}',
      orientation: newOrientation,
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
    _oldPositionsBeforeDrag[tile.id] = activeMonitors[index];
  }

  void _onMonitorDragEnd(MonitorTileData tile, BoxConstraints constraints) {
    if (activeProfileIndex == null) return;
    final mons = [...activeMonitors];
    final index = mons.indexWhere((m) => m.id == tile.id);
    if (index == -1) return;
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

  MonitorTileData _snapToEdges(MonitorTileData m, List<MonitorTileData> all) {
    double newX = m.x;
    double newY = m.y;
    for (var other in all) {
      if (other.id == m.id) continue;
      final left = m.x;
      final right = m.x + m.width;
      final top = m.y;
      final bottom = m.y + m.height;
      final oLeft = other.x;
      final oRight = other.x + other.width;
      final oTop = other.y;
      final oBottom = other.y + other.height;
      if ((left - oRight).abs() <= snapThreshold) newX = oRight;
      if ((right - oLeft).abs() <= snapThreshold) newX = oLeft - m.width;
      if ((top - oBottom).abs() <= snapThreshold) newY = oBottom;
      if ((bottom - oTop).abs() <= snapThreshold) newY = oTop - m.height;
    }
    return m.copyWith(x: newX, y: newY);
  }

  bool _hasOverlap(
      MonitorTileData updated, List<MonitorTileData> all, int idx) {
    final a = Rect.fromLTWH(updated.x, updated.y, updated.width, updated.height);
    for (int i = 0; i < all.length; i++) {
      if (i == idx) continue;
      final o = all[i];
      final b = Rect.fromLTWH(o.x, o.y, o.width, o.height);
      if (a.overlaps(b)) return true;
    }
    return false;
  }

  int? _findProfileWithAllCurrentMonitors() {
    for (int i = 0; i < profiles.length; i++) {
      final p = profiles[i];
      if (p.monitors.length != currentMonitors.length) continue;
      bool allMatch = true;
      for (var cm in currentMonitors) {
        if (!p.monitors.any((pm) =>
            pm.manufacturer.trim() == cm.manufacturer.trim())) {
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
                      return MonitorTile(
                        key: ValueKey(tile.id),
                        data: tile,
                        exists: currentMonitors.any((m) => m.manufacturer == tile.manufacturer),
                        snapThreshold: snapThreshold,
                        containerSize: Size(constraints.maxWidth, constraints.maxHeight),
                        scaleFactor: _scaleFactor,
                        offsetX: _offsetX,
                        offsetY: _offsetY,
                        originX: 0,
                        originY: 0,
                        onDragStart: () => _onMonitorDragStart(tile),
                        onUpdate: (updated) => _onMonitorUpdate(updated, constraints),
                        onDragEnd: () => _onMonitorDragEnd(tile, constraints),
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
                          onSelect: () => setState(() => activeProfileIndex = i),
                          onNameChanged: (newName) {
                            bool exists = profiles.any((p) => p.name.toLowerCase() == newName.toLowerCase() && p != profiles[i]);
                            if (exists) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('Profile name already exists!')),
                              );
                            } else {
                              setState(() { profiles[i].name = newName; _autoSave(); });
                            }
                          },
                          onDelete: () {
                            setState(() {
                              if (activeProfileIndex == i) activeProfileIndex = null;
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
    );
  }
}
