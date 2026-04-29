import 'dart:io';

import 'package:flutter/material.dart';
import 'package:kanshi_gui/models/monitor_tile_data.dart';
import 'package:kanshi_gui/services/layout_math.dart';
import 'package:kanshi_gui/state/kanshi_controller.dart';
import 'package:kanshi_gui/widgets/app_menu.dart';
import 'package:kanshi_gui/widgets/monitor_tile.dart';
import 'package:kanshi_gui/widgets/profile_sidebar.dart';
import 'package:kanshi_gui/widgets/safety_net_banner.dart';
import 'package:kanshi_gui/widgets/snap_lines_painter.dart';

/// Top-level page: hosts the AppBar, the sliding sidebar, and the layout
/// canvas. All business logic lives in [KanshiController]; this widget is
/// pure UI composition.
class HomePage extends StatefulWidget {
  final KanshiController controller;
  const HomePage({super.key, required this.controller});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage>
    with SingleTickerProviderStateMixin {
  late final AnimationController _iconController;
  bool _isSidebarOpen = false;
  final Map<String, MonitorTileData> _dragRollback = {};

  KanshiController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    _iconController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    _isSidebarOpen = c.activeProfileIndex == null;
    _iconController.value = _isSidebarOpen ? 1.0 : 0.0;
    c.onHotplugToast = (msg) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 2),
          content: Row(
            children: [
              const Icon(Icons.cable, color: Colors.white),
              const SizedBox(width: 8),
              Text(msg),
            ],
          ),
        ),
      );
    };
  }

  @override
  void dispose() {
    _iconController.dispose();
    super.dispose();
  }

  void _toggleSidebar() {
    setState(() {
      _isSidebarOpen = !_isSidebarOpen;
      _isSidebarOpen ? _iconController.forward() : _iconController.reverse();
    });
  }

  void _toast(OpResult r) {
    if (!mounted || r.message == null) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(r.message!)),
    );
  }

  void _maybeWarnBandwidth() {
    if (c.wouldExceedBandwidth(c.activeMonitors) && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
              'High total load (pixels*Hz). A monitor might stay black - try lowering refresh/resolution.'),
        ),
      );
    }
  }

  Future<void> _showLogs() async {
    final logFile = File('/tmp/kanshi_gui.log');
    var content = await logFile.exists()
        ? await logFile.readAsString()
        : 'Log file /tmp/kanshi_gui.log does not exist.';
    if (content.length > 6000) {
      content = content.substring(content.length - 6000);
    }
    if (!mounted) return;
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
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
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Close')),
        ],
      ),
    );
  }

  Future<void> _showHelp() async {
    if (!mounted) return;
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Tips'),
        content: const Text(
          'Tips:\n'
          '- Monitor menu: set resolution/Hz directly or test a custom mode (auto-revert after 10s unless you click "Keep").\n'
          '- Reload button at the top: save and restart kanshi.\n'
          '- Watch the bandwidth warning if many pixels/Hz are active.',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Close')),
        ],
      ),
    );
  }

  Future<void> _promptCustomMode(String id) async {
    final current = c.currentModeForOutput(id);
    final wCtl = TextEditingController(
        text: current?.width.toInt().toString() ?? '1920');
    final hCtl = TextEditingController(
        text: current?.height.toInt().toString() ?? '1080');
    final hzCtl = TextEditingController(
        text: current != null ? _formatHz(current.refresh) : '60');

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Custom Mode (Advanced)'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
                controller: wCtl,
                decoration: const InputDecoration(labelText: 'Width (px)'),
                keyboardType: TextInputType.number),
            TextField(
                controller: hCtl,
                decoration: const InputDecoration(labelText: 'Height (px)'),
                keyboardType: TextInputType.number),
            TextField(
                controller: hzCtl,
                decoration: const InputDecoration(labelText: 'Hz'),
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true)),
            const SizedBox(height: 8),
            const Text(
              'Warning: custom modes can fail. You can revert afterwards via "Revert last custom mode".',
              style: TextStyle(fontSize: 12),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Apply')),
        ],
      ),
    );
    if (ok != true) return;

    final w = double.tryParse(wCtl.text.trim());
    final h = double.tryParse(hCtl.text.trim());
    final hz = double.tryParse(hzCtl.text.trim());
    if (w == null || h == null || hz == null) {
      _toast(const OpResult.err('Invalid input for custom mode.'));
      return;
    }
    final r = await c.applyCustomMode(
      id, w, h, hz,
      onScheduledRevert: (target, label) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Applied custom mode: $label on $target'),
            action: SnackBarAction(
              label: 'Keep',
              onPressed: () => c.keepCustomMode(target),
            ),
          ),
        );
      },
    );
    if (!r.success) _toast(r);
    _maybeWarnBandwidth();
  }

  Future<void> _revertCustomMode(String id) async {
    final r = await c.revertCustomMode(id);
    _toast(r);
  }

  String _formatHz(double hz) {
    final isInt = (hz - hz.round()).abs() < 0.01;
    return isInt ? hz.round().toString() : hz.toStringAsFixed(3);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        return AppMenu(
          controller: c,
          onShowLogs: _showLogs,
          onShowHelp: _showHelp,
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
                  icon: const Icon(Icons.lightbulb_outline),
                  tooltip: 'Identify displays',
                  onPressed: c.identifyDisplays,
                ),
                IconButton(
                  icon: const Icon(Icons.refresh),
                  tooltip: 'Reload & restart kanshi',
                  onPressed: () async => _toast(await c.reloadAndApply()),
                ),
              ],
            ),
            bottomNavigationBar: SafetyNetBanner(controller: c),
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
                        final layout = LayoutMath.computeDisplay(
                          c.activeMonitors,
                          Size(constraints.maxWidth, constraints.maxHeight),
                        );
                        return Stack(
                          children: [
                            // Snap guide lines underneath the tiles.
                            Positioned.fill(
                              child: IgnorePointer(
                                child: CustomPaint(
                                  painter: SnapLinesPainter(
                                    lines: c.activeSnapLines,
                                    layout: layout,
                                    referenceMonitors: c.activeMonitors,
                                  ),
                                ),
                              ),
                            ),
                            ...layout.displayMonitors.map((tile) {
                              final original = c.activeMonitors
                                  .firstWhere((m) => m.id == tile.id);
                              return MonitorTile(
                                key: ValueKey(tile.id),
                                data: tile,
                                exists: c.monitorIsConnected(tile),
                                snapThreshold: c.snapThreshold,
                                containerSize: Size(constraints.maxWidth,
                                    constraints.maxHeight),
                                scaleFactor: layout.scaleFactor,
                                offsetX: layout.offsetX,
                                offsetY: layout.offsetY,
                                originX: 0,
                                originY: 0,
                                originalWidth: original.width,
                                originalHeight: original.height,
                                onDragStart: () => _onDragStart(original),
                                onUpdate: (updated) =>
                                    _onTileUpdate(updated, layout),
                                onDragEnd: () => _onDragEnd(tile),
                                onScale: (s) =>
                                    c.scaleMonitor(tile.id, s),
                                onScaleCommit: (s) async {
                                  c.scaleMonitor(tile.id, s,
                                      committing: true);
                                  final m = c.activeMonitors.firstWhere(
                                      (x) => x.id == tile.id,
                                      orElse: () => tile);
                                  _toast(await c.pushLiveApply(m));
                                },
                                onModeChange: (m) async =>
                                    _toast(await c.applyMode(tile.id, m)),
                                onToggleEnabled: (enabled) async {
                                  final r = await c.toggleEnabled(
                                      tile.id, enabled);
                                  _toast(r);
                                  if (enabled) _maybeWarnBandwidth();
                                },
                                onCustomMode: () =>
                                    _promptCustomMode(tile.id),
                                onCustomModeRevert: () =>
                                    _revertCustomMode(tile.id),
                                identifyNumber: c.identifyNumbers[tile.id],
                              );
                            }),
                          ],
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
                  child: ProfileSidebar(
                    controller: c,
                    onCreateCurrentSetup: c.createProfileFromCurrentSetup,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _onDragStart(MonitorTileData original) {
    _dragRollback[original.id] = original;
    c.beginDragSession(original.id);
  }

  void _onTileUpdate(MonitorTileData updated, DisplayLayout layout) {
    if (c.activeProfileIndex == null) return;
    final mons = c.activeMonitors;
    final idx = mons.indexWhere((m) => m.id == updated.id);
    if (idx == -1 || !mons[idx].enabled) return;

    // Translate viewport coordinates back into the absolute monitor space.
    final old = mons[idx];
    final oldRot = old.rotation;
    final newRot = updated.rotation;
    final wasLandscape = oldRot % 180 == 0;
    final isLandscape = newRot % 180 == 0;
    final newWidth = wasLandscape != isLandscape ? old.height : old.width;
    final newHeight = wasLandscape != isLandscape ? old.width : old.height;

    final minX = mons.map((m) => m.x).reduce((a, b) => a < b ? a : b);
    final minY = mons.map((m) => m.y).reduce((a, b) => a < b ? a : b);
    final newAbsX = minX + (updated.x - layout.offsetX) / layout.scaleFactor;
    final newAbsY = minY + (updated.y - layout.offsetY) / layout.scaleFactor;
    final newOrientation = newRot % 180 == 0 ? 'landscape' : 'portrait';

    final updatedAbs = MonitorTileData(
      id: old.id,
      manufacturer: old.manufacturer,
      x: newAbsX,
      y: newAbsY,
      width: newWidth,
      height: newHeight,
      scale: old.scale,
      rotation: newRot,
      refresh: old.refresh,
      resolution: newOrientation == 'landscape'
          ? '${newWidth.toInt()}x${newHeight.toInt()}'
          : '${newHeight.toInt()}x${newWidth.toInt()}',
      orientation: newOrientation,
      modes: old.modes,
      enabled: old.enabled,
    );
    c.updateMonitor(updatedAbs);
    // Drive snap guides while the drag is in progress.
    c.previewSnap(updatedAbs);
  }

  void _onDragEnd(MonitorTileData tile) async {
    final rollback = _dragRollback.remove(tile.id);
    final mons = c.activeMonitors;
    final idx = mons.indexWhere((m) => m.id == tile.id);
    if (idx == -1) return;
    c.snapAndCommit(mons[idx], rollback);
    c.endDragSession(tile.id);
    final committed = c.activeMonitors.firstWhere((m) => m.id == tile.id);
    _toast(await c.pushLiveApply(committed));
  }
}
