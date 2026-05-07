import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:kanshi_gui/models/monitor_tile_data.dart';
import 'package:kanshi_gui/services/app_settings.dart';
import 'package:kanshi_gui/services/kanshi_config_writer.dart';
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
  final AppSettings settings;
  /// Active-row highlight in the sidebar — read once at startup from
  /// `~/.config/sway/config`'s `client.focused` directive, null means
  /// "no usable accent in sway config, fall back to teal".
  final Color? activeAccent;
  const HomePage({
    super.key,
    required this.controller,
    required this.settings,
    this.activeAccent,
  });

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage>
    with SingleTickerProviderStateMixin {
  late final AnimationController _iconController;
  bool _isSidebarOpen = false;
  final Map<String, MonitorTileData> _dragRollback = {};
  bool? _wlMirrorAvailable;
  /// Last seen drag-cancel epoch — used to detect when the controller
  /// rolled back an in-flight drag (hotplug, profile switch) so the
  /// per-page `_dragRollback` map can be cleared. Otherwise abandoned
  /// rollbacks would linger past their tile being re-instantiated.
  int _lastSeenDragCancelEpoch = 0;

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
    _lastSeenDragCancelEpoch = c.dragCancelEpoch;
    c.addListener(_onControllerChanged);
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
    c.onProfileSuggestion = (s) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 6),
          content: Text(
            "Setup matches profile '${s.profileName}' "
            '(${s.matchedOutputs} of ${s.totalOutputs} outputs).',
          ),
          action: SnackBarAction(
            label: 'Switch',
            onPressed: () => c.setActiveProfile(s.profileIndex),
          ),
        ),
      );
    };
    // Auto-switch flag is read on every hotplug event, so changing it
    // via the settings menu takes effect on the next event without any
    // re-wiring.
    c.autoSwitchProfileEnabled = () => widget.settings.autoSwitchProfile;
    c.onAutoSwitchedProfile = (name) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 5),
          content: Text("Switched to profile '$name'"),
          action: SnackBarAction(
            label: 'Undo',
            // The auto-switch was pushed onto the undo stack like any
            // other mutation, so undo() walks back to the previous
            // active profile.
            // ignore: discarded_futures
            onPressed: () => c.undo(),
          ),
        ),
      );
    };
    if (c.supportsMirror) {
      // Cache the wl-mirror availability check so the menu wiring is sync.
      // ignore: discarded_futures
      c.mirrorRunner.isAvailable().then((v) {
        if (!mounted) return;
        setState(() => _wlMirrorAvailable = v);
      });
    } else {
      _wlMirrorAvailable = false;
    }
  }

  @override
  void dispose() {
    c.removeListener(_onControllerChanged);
    // Null the callback registrations the controller still holds so a
    // post-dispose event (e.g. a hotplug delivered between the
    // sub-cancel and the runtime tearing it down — also separately
    // guarded inside the controller via `_isDisposed`) can't fire a
    // stale closure that captures this disposed State's `context` and
    // `widget.settings`. Without this, on wizard re-entry the
    // previous HomePage's closures briefly co-exist with the fresh
    // ones.
    c.onHotplugToast = null;
    c.onProfileSuggestion = null;
    c.onAutoSwitchedProfile = null;
    c.autoSwitchProfileEnabled = null;
    _iconController.dispose();
    super.dispose();
  }

  void _onControllerChanged() {
    if (c.dragCancelEpoch != _lastSeenDragCancelEpoch) {
      _lastSeenDragCancelEpoch = c.dragCancelEpoch;
      // Drop any rollbacks recorded against the cancelled drag — the
      // controller has already restored the profile and the tile will
      // detect the cancel via its own epoch check. Without this clear,
      // a future drag-end against the same id could find a stale
      // rollback from a long-cancelled session.
      _dragRollback.clear();
    }
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
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.keyZ, control: true): () =>
            _toast(_awaitOp(c.undo())),
        const SingleActivator(LogicalKeyboardKey.keyZ,
            control: true, shift: true): () => _toast(_awaitOp(c.redo())),
        const SingleActivator(LogicalKeyboardKey.keyY, control: true): () =>
            _toast(_awaitOp(c.redo())),
      },
      child: Focus(
        autofocus: true,
        child: ListenableBuilder(
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
                _SettingsMenu(settings: widget.settings),
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
                          pinnedBounds: c.pinnedLayoutBounds,
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
                                    accent: widget.activeAccent,
                                  ),
                                ),
                              ),
                            ),
                            ...layout.displayMonitors.map((tile) {
                              final original = c.activeMonitors
                                  .firstWhere((m) => m.id == tile.id);
                              final mirrorEnabled = c.supportsMirror &&
                                  (_wlMirrorAvailable ?? false);
                              // Valid mirror sources: enabled, not the
                              // tile itself, not already a mirror dst
                              // (no chains).
                              final sources = mirrorEnabled
                                  ? c.activeMonitors
                                      .where((m) =>
                                          m.id != tile.id &&
                                          m.enabled &&
                                          m.mirrorOf == null)
                                      .toList()
                                  : const <MonitorTileData>[];
                              final enabledMons = c.activeMonitors
                                  .where((m) => m.enabled)
                                  .toList();
                              final ranks =
                                  resolveWorkspaceRanks(enabledMons);
                              final rankIdx = ranks
                                  .indexWhere((e) => e.id == tile.id);
                              final rankEntry =
                                  rankIdx >= 0 ? ranks[rankIdx] : null;
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
                                onSetMirror: mirrorEnabled
                                    ? (srcId) async => _toast(
                                        await c.setMirror(tile.id, srcId))
                                    : null,
                                mirrorSources: sources,
                                mirroredBy:
                                    layout.mirroredBy[tile.id] ??
                                        const <String>[],
                                onStopMirroredBy: mirrorEnabled
                                    ? (destId) async => _toast(
                                        await c.setMirror(destId, null))
                                    : null,
                                workspacePositionCount: enabledMons.length,
                                workspacePositionEffective:
                                    rankEntry?.rank,
                                workspacePositionExplicit:
                                    rankEntry?.explicit ?? false,
                                onSetWorkspaceRank: (r) async => _toast(
                                    await c.setWorkspaceRank(tile.id, r)),
                                readDragCancelEpoch: () =>
                                    c.dragCancelEpoch,
                                mirroredByNumbers: [
                                  for (final dst in layout
                                          .mirroredBy[tile.id] ??
                                      const <String>[])
                                    if (c.identifyNumbers[dst] != null)
                                      c.identifyNumbers[dst]!,
                                ],
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
                    activeAccent: widget.activeAccent,
                    onCreateCurrentSetup: c.createProfileFromCurrentSetup,
                  ),
                ),
              ],
            ),
          ),
        );
            },
          ),
        ),
      );
  }

  /// Wraps an async OpResult so `_toast` can be called synchronously
  /// from a CallbackShortcuts binding. The binding doesn't await, so we
  /// just kick off the future and toast its result when it lands.
  OpResult _awaitOp(Future<OpResult> op) {
    op.then(_toast).catchError((Object _) {/* ignore */});
    return const OpResult.ok();
  }

  void _onDragStart(MonitorTileData original) {
    _dragRollback[original.id] = original;
    c.beginDragSession(original.id, original);
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

    // Use the origin the *current* layout actually projected from. While a
    // drag is in progress this is the pinned snapshot from drag-start, so
    // the viewport↔abs round-trip stays self-consistent and the dragged
    // tile follows the cursor pixel-perfectly even when its coordinates
    // go negative.
    final newAbsX = layout.originX +
        (updated.x - layout.offsetX) / layout.scaleFactor;
    final newAbsY = layout.originY +
        (updated.y - layout.offsetY) / layout.scaleFactor;
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
    final mons = c.activeMonitors;
    final idx = mons.indexWhere((m) => m.id == tile.id);
    if (idx == -1) {
      _dragRollback.remove(tile.id);
      return;
    }
    final dragged = mons[idx];
    // Drag-to-mirror: if the dragged tile lands substantially on top of
    // another enabled tile and the backend supports mirroring, ask the
    // user whether they meant to drop-as-mirror instead of drop-as-move.
    // The check runs *before* snap-and-commit so a "Mirror" answer can
    // restore the original position cleanly via the rollback.
    final mirrorTarget = c.supportsMirror && _wlMirrorAvailable == true
        ? LayoutMath.detectMirrorDropTarget(dragged: dragged, all: mons)
        : null;
    if (mirrorTarget != null) {
      final confirm = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text("Mirror ${dragged.id} onto ${mirrorTarget.id}?"),
          content: Text(
            '${dragged.id} will display the same content as '
            '${mirrorTarget.id}. Its position is locked to the source — '
            'release the mirror via the three-dot menu when you want '
            '${dragged.id} back as an independent screen.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Mirror'),
            ),
          ],
        ),
      );
      if (confirm == true) {
        // Roll back the drag-position write so the mirror takes over
        // an unchanged layout, then set up the mirror.
        final rollback = _dragRollback.remove(dragged.id);
        if (rollback != null) c.updateMonitor(rollback);
        c.endDragSession(dragged.id);
        _toast(await c.setMirror(dragged.id, mirrorTarget.id));
        return;
      }
    }
    final rollback = _dragRollback.remove(tile.id);
    c.snapAndCommit(mons[idx], rollback);
    c.endDragSession(tile.id);
    final committed = c.activeMonitors.firstWhere((m) => m.id == tile.id);
    _toast(await c.pushLiveApply(committed));
  }

}

/// Gear-icon menu in the AppBar holding GUI-private toggles. The
/// kanshi config itself is unaffected — these settings live in
/// `~/.config/kanshi-gui/settings.json` and are read on startup plus
/// re-read on each hotplug event (via the controller's
/// `autoSwitchProfileEnabled` callback) so flipping the toggle takes
/// effect on the next event without an app restart.
class _SettingsMenu extends StatefulWidget {
  final AppSettings settings;
  const _SettingsMenu({required this.settings});

  @override
  State<_SettingsMenu> createState() => _SettingsMenuState();
}

class _SettingsMenuState extends State<_SettingsMenu> {
  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<void>(
      icon: const Icon(Icons.settings),
      tooltip: 'Settings',
      itemBuilder: (context) => [
        PopupMenuItem<void>(
          // Tap target is the whole row, but the switch handles the
          // toggle itself so we don't need an onTap on the menu item.
          enabled: false,
          padding: EdgeInsets.zero,
          child: StatefulBuilder(
            builder: (context, setLocalState) {
              return SwitchListTile(
                dense: true,
                title: const Text('Auto-switch profile on hotplug'),
                subtitle: const Text(
                  'Switch to the matching profile when a known monitor '
                  'set is plugged in.',
                ),
                value: widget.settings.autoSwitchProfile,
                onChanged: (v) {
                  setLocalState(() {
                    widget.settings.autoSwitchProfile = v;
                  });
                  // Persist asynchronously; UI doesn't need to wait.
                  // ignore: discarded_futures
                  widget.settings.save();
                },
              );
            },
          ),
        ),
      ],
    );
  }
}
