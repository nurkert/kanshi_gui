import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/monitor_tile_data.dart';
import '../providers/profile_provider.dart';
import '../widgets/monitor_tile.dart';
import '../widgets/profile_list_item.dart';
import '../utils/constants.dart';

/// Main screen showing monitor layout and profile sidebar.
class HomePage extends StatefulWidget {
  const HomePage({Key? key}) : super(key: key);

  @override
  _HomePageState createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  Timer? _saveTimer;
  List<MonitorTileData> _displayMonitors = [];
  double _scale = 1, _offsetX = 0, _offsetY = 0;
  bool _sidebarOpen = true;

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<ProfileProvider>();
    final profiles = provider.profiles;
    final activeIdx = provider.activeIndex;
    final activeMonitors =
        activeIdx != null ? profiles[activeIdx].monitors : [];

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.menu),
          onPressed: () => setState(() => _sidebarOpen = !_sidebarOpen),
        ),
        title: const Text('Kanshi GUI'),
      ),
      body: Row(
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            width: _sidebarOpen ? 300 : 0,
            color: Colors.grey[900],
            child: ListView.builder(
              itemCount: profiles.length,
              itemBuilder:
                  (_, i) => ProfileListItem(
                    profile: profiles[i],
                    isActive: i == activeIdx,
                    onSelect: () => provider.selectProfile(i),
                    onNameChanged: (name) => provider.renameProfile(i, name),
                    onDelete: () => provider.deleteProfile(i),
                    exists: true,
                  ),
            ),
          ),
          Expanded(
            child: LayoutBuilder(
              builder: (_, constraints) {
                _updateDisplay(
                  activeMonitors.cast<MonitorTileData>(),
                  constraints.maxWidth,
                  constraints.maxHeight,
                );
                return Stack(
                  children:
                      _displayMonitors.map((m) {
                        return MonitorTile(
                          key: ValueKey(m.id),
                          data: m,
                          exists: true,
                          snapThreshold: AppConstants.snapThreshold,
                          containerSize: Size(
                            constraints.maxWidth,
                            constraints.maxHeight,
                          ),
                          scaleFactor: _scale,
                          offsetX: _offsetX,
                          offsetY: _offsetY,
                          onUpdate: (upd) => _onTileUpdate(upd, provider),
                          onDragStart: () {},
                          onDragEnd: () => _autoSave(provider),
                        );
                      }).toList(),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  /// Scales and centers monitors within available space.
  void _updateDisplay(List<MonitorTileData> mons, double maxW, double maxH) {
    if (mons.isEmpty) return;
    final xs = mons.map((m) => m.x).reduce((a, b) => a < b ? a : b);
    final ys = mons.map((m) => m.y).reduce((a, b) => a < b ? a : b);
    final xe = mons.map((m) => m.x + m.width).reduce((a, b) => a > b ? a : b);
    final ye = mons.map((m) => m.y + m.height).reduce((a, b) => a > b ? a : b);
    final bw = xe - xs;
    final bh = ye - ys;
    final sx = bw == 0 ? 1 : (maxW * 0.8) / bw;
    final sy = bh == 0 ? 1 : (maxH * 0.8) / bh;
    _scale = [sx, sy, 1.0].reduce((a, b) => a < b ? a : b).toDouble();
    final scaledW = bw * _scale;
    final scaledH = bh * _scale;
    _offsetX = (maxW - scaledW) / 2 - xs * _scale;
    _offsetY = (maxH - scaledH) / 2 - ys * _scale;
    _displayMonitors =
        mons
            .map(
              (m) => m.copyWith(
                x: m.x * _scale + _offsetX,
                y: m.y * _scale + _offsetY,
                width: m.width * _scale,
                height: m.height * _scale,
              ),
            )
            .toList();
  }

  /// Handles tile drag/rotation updates.
  void _onTileUpdate(MonitorTileData updated, ProfileProvider provider) {
    final idx = provider.activeIndex!;
    final list = provider.profiles[idx].monitors;
    final i = list.indexWhere((m) => m.id == updated.id);
    if (i == -1) return;
    list[i] = updated;
    _autoSave(provider);
  }

  /// Debounced save of profile layout.
  void _autoSave(ProfileProvider provider) {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 500), () {
      provider.saveCurrentLayout();
    });
  }
}
