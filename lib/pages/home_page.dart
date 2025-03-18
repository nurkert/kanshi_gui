// lib/pages/home_page.dart

import 'dart:async';
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

  /// Geladene Profile aus der Config
  List<Profile> profiles = [];

  /// Aktuelles Setup – Achte auf korrekte Maße (bei gedrehten Monitoren vertauschte width/height)
  List<MonitorTileData> currentMonitors = [
    MonitorTileData(
      id: "InfoVision Optoelectronics (Kunshan) Co.,Ltd China 0x057D Unknown",
      x: 3000,
      y: 2,
      width: 1920,
      height: 1080,
      rotation: 0,
      resolution: "1920x1080",
      orientation: "landscape",
    ),
    MonitorTileData(
      id: "Samsung Electric Company S24E450 H4ZJ700279",
      x: 1080,
      y: 0,
      width: 1920,
      height: 1080,
      rotation: 0,
      resolution: "1920x1080",
      orientation: "landscape",
    ),
    MonitorTileData(
      id: "Samsung Electric Company S24E450 H4ZJ704845",
      x: 0,
      y: 0,
      width: 1080,  // width und height vertauscht für portrait
      height: 1920,
      rotation: 90,
      resolution: "1080x1920",
      orientation: "portrait",
    ),
  ];

  /// Welches Profil wird gerade bearbeitet?
  int? activeProfileIndex;

  /// Snap-Toleranz in Pixeln
  final double snapThreshold = 50.0;

  /// Skalierungs-/Positionsparameter
  double _scaleFactor = 1.0;
  double _offsetX = 0;
  double _offsetY = 0;
  bool _scalingInitialized = false;

  /// Die skalierten Monitor-Daten zur Anzeige
  List<MonitorTileData> _displayMonitors = [];

  /// Alte Positionen für Overlap-Revert
  Map<String, MonitorTileData> _oldPositionsBeforeDrag = {};

  /// Timer für Debounced-Save
  Timer? _saveTimer;

  /// Greift auf aktive Monitore (des selektierten Profils) zu.
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
    _loadConfig();
  }

  /// Profile laden und ggf. Standard-Auswahl setzen.
  void _loadConfig() async {
    List<Profile> loaded = await _configService.loadProfiles();
    setState(() {
      profiles = loaded;
      // Falls ein "Current Setup" vorhanden ist, automatisch als aktiv auswählen:
      int? currentSetupIndex = _findProfileWithAllCurrentMonitors();
      if (currentSetupIndex != null) {
        activeProfileIndex = currentSetupIndex;
      } else if (profiles.isNotEmpty) {
        activeProfileIndex = 0;
      }
    });
  }

  /// Verzögertes Speichern (debounced)
  void _debouncedAutoSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 600), () {
      _configService.saveProfiles(profiles);
      debugPrint("Debounced Auto-Save: Konfiguration gespeichert");
    });
  }

  void _autoSave() {
    _debouncedAutoSave();
  }

  /// Aktualisiert die skalierten Monitor-Daten (_displayMonitors) anhand der absoluten Koordinaten.
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
    _oldPositionsBeforeDrag[tile.id] = activeMonitors[index];
  }

  void _onMonitorDragEnd(MonitorTileData tile, BoxConstraints constraints) {
    if (activeProfileIndex == null) return;
    final index = activeMonitors.indexWhere((m) => m.id == tile.id);
    if (index == -1) return;
    final newMonitors = [...activeMonitors];
    final updated = _snapToEdges(newMonitors[index], newMonitors);
    newMonitors[index] = updated;
    if (_hasOverlap(updated, newMonitors, index)) {
      final oldPos = _oldPositionsBeforeDrag[tile.id];
      if (oldPos != null) {
        newMonitors[index] = oldPos;
      }
    }
    setState(() {
      profiles[activeProfileIndex!].monitors = newMonitors;
      _oldPositionsBeforeDrag.remove(tile.id);
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
      if (other.id == m.id) continue;
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
      _scalingInitialized = false;
    });
  }

  int? _findProfileWithAllCurrentMonitors() {
    bool idsMatch(String id1, String id2) {
      String base1 = id1.replaceAll("Unknown", "").trim();
      String base2 = id2.replaceAll("Unknown", "").trim();
      return base1 == base2;
    }
    for (int i = 0; i < profiles.length; i++) {
      final profile = profiles[i];
      if (profile.monitors.length != currentMonitors.length) continue;
      bool allMatch = true;
      for (final cm in currentMonitors) {
        if (!profile.monitors.any((pm) => idsMatch(pm.id, cm.id))) {
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

  @override
  Widget build(BuildContext context) {
    final currentSetupIndex = _findProfileWithAllCurrentMonitors();
    return Scaffold(
      appBar: AppBar(
        title: const Text("Kanshi GUI"),
        actions: [
          IconButton(
            icon: const Icon(Icons.update),
            tooltip: 'Skalierung aktualisieren',
            onPressed: () {
              setState(() {
                _scalingInitialized = false;
              });
            },
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Sway neu laden',
            onPressed: () {
              debugPrint("Sway reload ausgeführt");
            },
          ),
        ],
      ),
      body: Row(
        children: [
          // Sidebar
          Container(
            width: 320,
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
          // Layout-Bereich
          Expanded(
            child: MouseRegion(
              cursor: SystemMouseCursors.basic,
              child: Container(
                color: Colors.black,
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    if (!_scalingInitialized) {
                      _updateDisplayMonitors(constraints);
                      _scalingInitialized = true;
                    } else {
                      _updateDisplayMonitors(constraints);
                    }
                    return Stack(
                      children: [
                        for (final tile in _displayMonitors)
                          MonitorTile(
                            key: ValueKey(tile.id),
                            data: tile,
                            exists: currentMonitors.any((m) => m.id == tile.id),
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
        ],
      ),
    );
  }
}
