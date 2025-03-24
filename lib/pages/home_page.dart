// lib/pages/home_page.dart

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

class _HomePageState extends State<HomePage> {
  final ConfigService _configService = ConfigService();

  /// Loaded profiles from config.
  List<Profile> profiles = [];

  /// List of currently connected monitors.
  List<MonitorTileData> currentMonitors = [];

  Future<List<MonitorTileData>> getConnectedMonitors() async {
    final result = await Process.run('swaymsg', ['-t', 'get_outputs']);
    if (result.exitCode != 0) {
      throw Exception('swaymsg failed: ${result.stderr}');
    }
    final outputs = jsonDecode(result.stdout) as List;
    List<MonitorTileData> monitors = [];
    for (var output in outputs) {
      if (output['active'] == true) {
        String id = output['name']; // z.B. "eDP-1"
        String make = output['make'] ?? "";
        String model = output['model'] ?? "";
        String manufacturer = (make + " " + model).trim();
        if (manufacturer.isEmpty) {
          manufacturer = id;
        }
        double x = (output['rect']['x'] as num).toDouble();
        double y = (output['rect']['y'] as num).toDouble();
        double width = (output['rect']['width'] as num).toDouble();
        double height = (output['rect']['height'] as num).toDouble();
        int rotation = 0;
        String orientation = (width >= height) ? "landscape" : "portrait";
        String resolution = "${width.toInt()}x${height.toInt()}";

        // Verwende den vollen Herstellerstring als id für konsistentes Matching.
        monitors.add(MonitorTileData(
          id: id, // Verwende den tatsächlichen, eindeutigen Output-Namen
          manufacturer: manufacturer,
          x: x,
          y: y,
          width: width,
          height: height,
          rotation: rotation,
          resolution: resolution,
          orientation: orientation,
        ));
      }
    }
    return monitors;
  }

  // Passt das "Current Setup" an die aktuell verbundenen Monitore an.
  Future<void> ensureCurrentSetupMatchesConnectedMonitors() async {
    List<MonitorTileData> connected = await getConnectedMonitors();

    // Verwende den vollen Herstellerstring als Normalisierung.
    Set<String> normalize(List<MonitorTileData> list) =>
        list.map((m) => m.manufacturer.trim()).toSet();

    Set<String> connectedIds = normalize(connected);

    int index = profiles.indexWhere((p) => p.name == "Current Setup");

    if (index == -1) {
      Profile currentSetup = Profile(name: "Current Setup", monitors: connected);
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
          profiles[index] = Profile(name: "Current Setup", monitors: connected);
          activeProfileIndex = index;
        });
      }
    }

    // Schreibe "Current Setup" in die Datei, die kanshi als aktives Profil erwartet.
    final home = Platform.environment['HOME'] ?? '/home/nburkert';
    final file = File("$home/.config/kanshi/current");
    await file.create(recursive: true);
    await file.writeAsString("Current Setup");

    _autoSave();
  }

  /// Welches Profil ist aktuell aktiv?
  int? activeProfileIndex;

  /// Sidebar state – true, wenn Sidebar sichtbar.
  bool _isSidebarOpen = false;

  /// Snap threshold (in pixels)
  final double snapThreshold = 500.0;

  /// Scaling- und Positionierungsparameter.
  double _scaleFactor = 1.0;
  double _offsetX = 0;
  double _offsetY = 0;
  bool _scalingInitialized = false;

  /// Skaliertes Monitor-Layout für die Anzeige.
  List<MonitorTileData> _displayMonitors = [];

  /// Alte Positionen vor Drag zum Zurücksetzen.
  Map<String, MonitorTileData> _oldPositionsBeforeDrag = {};

  /// Timer für debounced saving.
  Timer? _saveTimer;

  /// Aktive Monitore (aus dem aktiven Profil).
  List<MonitorTileData> get activeMonitors {
    if (activeProfileIndex == null) {
      return [];
    } else {
      return profiles[activeProfileIndex!].monitors;
    }
  }

  @override
  void initState() {
    super.initState();
    _initSetup();
  }

  Future<void> _initSetup() async {
    await _loadConfig();
    await _updateConnectedMonitors();
    await ensureCurrentSetupMatchesConnectedMonitors();
  }

  Future<void> _updateConnectedMonitors() async {
    try {
      List<MonitorTileData> monitors = await getConnectedMonitors();
      setState(() {
        currentMonitors = monitors;
      });
    } catch (e) {
      debugPrint("Error getting connected monitors: $e");
    }
  }

  /// Lädt die Profile und setzt das Standardprofil.
  Future<void> _loadConfig() async {
    List<Profile> loaded = await _configService.loadProfiles();
    setState(() {
      profiles = loaded;
      int? currentSetupIndex = _findProfileWithAllCurrentMonitors();
      if (currentSetupIndex != null) {
        activeProfileIndex = currentSetupIndex;
      } else if (profiles.isNotEmpty) {
        activeProfileIndex = 0;
      }
      _isSidebarOpen = (activeProfileIndex == null);
    });
  }

  void _debouncedAutoSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 600), () {
      _configService.saveProfiles(profiles);
      debugPrint("Debounced Auto-Save: Configuration saved");
    });
  }

  void _autoSave() {
    _debouncedAutoSave();
  }

  /// Aktualisiert das angezeigte Monitor-Layout (skaliert) basierend auf absoluten Koordinaten.
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
    if (scale > 1.0) scale = 1.0;
    _scaleFactor = scale;

    double scaledBW = boundingWidth * scale;
    double scaledBH = boundingHeight * scale;
    _offsetX = (constraints.maxWidth - scaledBW) / 2;
    _offsetY = (constraints.maxHeight - scaledBH) / 2;

    _displayMonitors = mons.map((m) {
      double dx = (m.x - minX) * scale + _offsetX;
      double dy = (m.y - minY) * scale + _offsetY;
      double dw = m.width * scale;
      double dh = m.height * scale;
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
    final oldRotation = oldMonitor.rotation;
    final newRotation = updatedTile.rotation;

    bool wasLandscape = (oldRotation % 180 == 0);
    bool isLandscape = (newRotation % 180 == 0);
    double newWidth = oldMonitor.width;
    double newHeight = oldMonitor.height;
    if (wasLandscape != isLandscape) {
      double temp = newWidth;
      newWidth = newHeight;
      newHeight = temp;
    }

    final minX = mons.map((m) => m.x).reduce(min);
    final minY = mons.map((m) => m.y).reduce(min);
    final newAbsX = minX + (updatedTile.x - _offsetX) / _scaleFactor;
    final newAbsY = minY + (updatedTile.y - _offsetY) / _scaleFactor;
    final newOrientation = (newRotation % 180 == 0) ? "landscape" : "portrait";

    final newAbsMonitor = oldMonitor.copyWith(
      x: newAbsX,
      y: newAbsY,
      rotation: newRotation,
      orientation: newOrientation,
      width: newWidth,
      height: newHeight,
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
    _oldPositionsBeforeDrag[tile.manufacturer] = activeMonitors[index];
  }

  void _onMonitorDragEnd(MonitorTileData tile, BoxConstraints constraints) {
    if (activeProfileIndex == null) return;
    final index = activeMonitors.indexWhere((m) => m.id == tile.id);
    if (index == -1) return;
    final newMonitors = [...activeMonitors];
    final updated = _snapToEdges(newMonitors[index], newMonitors);
    newMonitors[index] = updated;
    if (_hasOverlap(updated, newMonitors, index)) {
      final oldPos = _oldPositionsBeforeDrag[tile.manufacturer];
      if (oldPos != null) {
        newMonitors[index] = oldPos;
      }
    }
    setState(() {
      profiles[activeProfileIndex!].monitors = newMonitors;
      _oldPositionsBeforeDrag.remove(tile.manufacturer);
      _buildAndSave(constraints);
    });
  }

  void _buildAndSave(BoxConstraints constraints) {
    _updateDisplayMonitors(constraints);
    _autoSave();
  }

  MonitorTileData _snapToEdges(MonitorTileData m, List<MonitorTileData> all) {
    double newX = m.x;
    double newY = m.y;
    for (int i = 0; i < all.length; i++) {
      final other = all[i];
      if (other.manufacturer == m.manufacturer) continue;
      final left = m.x;
      final right = m.x + m.width;
      final top = m.y;
      final bottom = m.y + m.height;
      final oLeft = other.x;
      final oRight = other.x + other.width;
      final oTop = other.y;
      final oBottom = other.y + other.height;
      if ((left - oRight).abs() <= snapThreshold) {
        newX = oRight;
      }
      if ((right - oLeft).abs() <= snapThreshold) {
        newX = oLeft - m.width;
      }
      if ((top - oBottom).abs() <= snapThreshold) {
        newY = oBottom;
      }
      if ((bottom - oTop).abs() <= snapThreshold) {
        newY = oTop - m.height;
      }
    }
    return m.copyWith(x: newX, y: newY);
  }

  bool _hasOverlap(MonitorTileData updated, List<MonitorTileData> all, int updatedIndex) {
    final rectA = Rect.fromLTWH(updated.x, updated.y, updated.width, updated.height);
    for (int i = 0; i < all.length; i++) {
      if (i == updatedIndex) continue;
      final o = all[i];
      final rectB = Rect.fromLTWH(o.x, o.y, o.width, o.height);
      if (rectA.overlaps(rectB)) {
        return true;
      }
    }
    return false;
  }

  void _selectProfile(int index) {
    setState(() {
      activeProfileIndex = index;
    });
  }

  int? _findProfileWithAllCurrentMonitors() {
    bool manufacturersMatch(String m1, String m2) {
      return m1.trim() == m2.trim();
    }
    for (int i = 0; i < profiles.length; i++) {
      final profile = profiles[i];
      if (profile.monitors.length != currentMonitors.length) continue;
      bool allMatch = true;
      for (final cm in currentMonitors) {
        if (!profile.monitors.any((pm) => manufacturersMatch(pm.manufacturer, cm.manufacturer))) {
          allMatch = false;
          break;
        }
      }
      if (allMatch) {
        return i;
      }
    }
    return null;
  }

  void _createCurrentSetup() {
    final newProfile = Profile(
      name: "Current Setup",
      monitors: currentMonitors.map((m) {
        if (m.rotation == 90 || m.rotation == 270) {
          return m.copyWith(
            width: m.height,
            height: m.width,
            orientation: "portrait",
          );
        }
        return m;
      }).toList(),
    );
    setState(() {
      profiles.add(newProfile);
      activeProfileIndex = profiles.length - 1;
    });
    _autoSave();
  }

  void _toggleSidebar() {
    setState(() {
      _isSidebarOpen = !_isSidebarOpen;
    });
  }

  @override
  Widget build(BuildContext context) {
    final currentSetupIndex = _findProfileWithAllCurrentMonitors();

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.menu),
          tooltip: 'Toggle Sidebar',
          onPressed: _toggleSidebar,
        ),
        title: const Text("Kanshi GUI"),
      ),
      body: Stack(
        children: [
          // Main content area
          Positioned.fill(
            left: _isSidebarOpen ? 320 : 0,
            child: MouseRegion(
              cursor: SystemMouseCursors.basic,
              child: Container(
                color: Colors.black,
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    _updateDisplayMonitors(constraints);
                    return Stack(
                      children: [
                        for (final tile in _displayMonitors)
                          MonitorTile(
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
                            onUpdate: (updatedTile) {
                              _onMonitorUpdate(updatedTile, constraints);
                            },
                            onDragEnd: () {
                              _onMonitorDragEnd(tile, constraints);
                            },
                          ),
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
          // Sidebar
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
                          isActive: (activeProfileIndex == i),
                          onSelect: () => _selectProfile(i),
                          onNameChanged: (newName) {
                            bool nameExists = profiles.any((p) =>
                                p.name.toLowerCase() == newName.toLowerCase() &&
                                p != profiles[i]);
                            if (nameExists) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text("Profile name already exists!"),
                                ),
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
                  if (currentSetupIndex == null)
                    Padding(
                      padding: const EdgeInsets.all(8.0),
                      child: ElevatedButton(
                        onPressed: _createCurrentSetup,
                        child: const Text("Create Current Setup"),
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
