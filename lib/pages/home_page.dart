import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:kanshi_gui/models/monitor_tile_data.dart';
import 'package:kanshi_gui/pages/settings_page.dart';
import 'package:kanshi_gui/services/app_settings.dart';
import 'package:kanshi_gui/services/kanshi_config_writer.dart';
import 'package:kanshi_gui/services/layout_math.dart';
import 'package:kanshi_gui/state/app_status.dart';
import 'package:kanshi_gui/state/kanshi_controller.dart';
import 'package:kanshi_gui/widgets/app_menu.dart';
import 'package:kanshi_gui/widgets/assurance_line.dart';
import 'package:kanshi_gui/widgets/dot_grid_background.dart';
import 'package:kanshi_gui/widgets/editor_header.dart';
import 'package:kanshi_gui/widgets/monitor_tile.dart';
import 'package:kanshi_gui/widgets/presets_bar.dart';
import 'package:kanshi_gui/widgets/profile_rail.dart';
import 'package:kanshi_gui/widgets/properties_inspector.dart';
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
  /// Invoked when the settings page changes a theme/accent setting so the
  /// app shell (MaterialApp) can rebuild. Optional so tests can omit it.
  final VoidCallback? onAppearanceChanged;
  const HomePage({
    super.key,
    required this.controller,
    required this.settings,
    this.activeAccent,
    this.onAppearanceChanged,
  });

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final Map<String, MonitorTileData> _dragRollback = {};
  bool? _wlMirrorAvailable;
  /// Environment warnings from [KanshiController.checkHealth], surfaced as a
  /// dismissible banner. Empty until the post-frame probe completes.
  List<String> _healthWarnings = const [];
  bool _healthDismissed = false;
  /// Output id shown in the properties inspector, or null when none selected.
  String? _selectedId;
  /// Last seen drag-cancel epoch — used to detect when the controller
  /// rolled back an in-flight drag (hotplug, profile switch) so the
  /// per-page `_dragRollback` map can be cleared. Otherwise abandoned
  /// rollbacks would linger past their tile being re-instantiated.
  int _lastSeenDragCancelEpoch = 0;

  KanshiController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    _lastSeenDragCancelEpoch = c.dragCancelEpoch;
    c.addListener(_onControllerChanged);
    c.onHotplugToast = (msg) {
      if (!mounted) return;
      // Read the toggle at fire-time so the settings page takes effect
      // without re-wiring the callback.
      if (!widget.settings.hotplugToasts) return;
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
      if (!widget.settings.profileSuggestionToasts) return;
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
    c.onConfigSaveBlocked = (reason) {
      if (!mounted) return;
      // Persistent SnackBar: the user needs to know that their edits are NOT
      // landing on disk. Auto-dismissing this would leave them wondering why
      // their layout reverts after the next launch. No action button — only
      // the user fixing their config (or the GUI relaunching) clears it.
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          duration: const Duration(days: 1),
          content: Text(reason),
        ),
      );
    };
    c.onSafetyNetRevertFailed = (label, error) {
      if (!mounted) return;
      // The worst moment the app has: the risky change is still in effect —
      // the user may be looking at a black screen — and the automatic way
      // out just failed. Persistent, with a retry; never auto-dismissed.
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            duration: const Duration(days: 1),
            backgroundColor: Theme.of(context).colorScheme.errorContainer,
            content: Text(
              "Could not undo '$label' automatically: $error",
              style: TextStyle(
                  color: Theme.of(context).colorScheme.onErrorContainer),
            ),
            action: SnackBarAction(
              label: 'Try again',
              onPressed: () async => _toast(await c.retrySafetyNetReverts()),
            ),
          ),
        );
    };
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
    // If the controller's `init()` already found a reason saving is refused —
    // `include` directives, or syntax the parser did not model — say so on
    // the first frame. Without this the user would only learn their saves are
    // blocked on their first attempted edit.
    final blocked = c.saveBlockedReason;
    if (blocked != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        c.onConfigSaveBlocked?.call(blocked);
      });
    }
    // Environment health probe (kanshi present/running, wl-mirror) — surface
    // any warnings as a dismissible banner once the first frame is up.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final warnings = await c.checkHealth();
      if (!mounted || warnings.isEmpty) return;
      setState(() => _healthWarnings = warnings);
    });
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
    c.onConfigSaveBlocked = null;
    c.onSafetyNetRevertFailed = null;
    c.autoSwitchProfileEnabled = null;
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


  /// The single status the assurance line shows, in strict priority order:
  /// attention beats working beats settled. A decision (the safety-net
  /// countdown) outranks all of them and is rendered by its own surface
  /// above the line, because the user may be looking at a screen that just
  /// went black and a 36px row at the bottom is the wrong shape for a
  /// question they must answer.
  AppStatus _statusFor(KanshiController c) {
    final blocked = c.saveBlockedReason;
    if (blocked != null) {
      return AppStatus(
        level: StatusLevel.attention,
        message: blocked,
        actionLabel: 'Show file',
        onAction: () => _revealConfigInFileManager(),
      );
    }
    if (c.hasFailedSafetyNetRevert) {
      return AppStatus(
        level: StatusLevel.attention,
        message: "I could not put your display back on my own.",
        actionLabel: 'Try again',
        onAction: () async => _toast(await c.retrySafetyNetReverts()),
      );
    }
    if (c.hasLayoutDrift) {
      return AppStatus(
        level: StatusLevel.attention,
        message: c.layoutDriftIssues.length == 1
            ? 'A screen is not where you put it.'
            : '${c.layoutDriftIssues.length} screens are not where you put '
                'them.',
        actionLabel: 'Put back',
        onAction: () async => _toast(await c.reapplyActiveProfile()),
      );
    }
    if (c.kanshiRunning == false) {
      return AppStatus(
        level: StatusLevel.attention,
        message: "kanshi isn't running, so this won't come back after a "
            'reboot.',
        actionLabel: 'Details',
        onAction: _showHelp,
      );
    }
    if (_healthWarnings.isNotEmpty && !_healthDismissed) {
      return AppStatus(
        level: StatusLevel.attention,
        message: _healthWarnings.first,
        actionLabel: 'Dismiss',
        onAction: () => setState(() => _healthDismissed = true),
      );
    }
    return AppStatus.settled(
      c.assuranceLevel,
      screenCount: c.activeMonitors.where((m) => m.enabled).length,
    );
  }

  void _revealConfigInFileManager() {
    // Deliberately just tells the user where it is: opening a file manager
    // from a Wayland desktop app is a portal dance that can fail silently,
    // and a path they can copy always works.
    _toast(OpResult.err('Your kanshi config: ${c.config.configPath}'));
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
            bottomNavigationBar: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // A decision outranks every other level, so it sits above
                // the line rather than inside it.
                SafetyNetBanner(controller: c),
                AssuranceLine(
                  status: _statusFor(c),
                  trailingNote: c.assuranceLevel == AssuranceLevel.verified
                      ? 'verified'
                      : null,
                ),
              ],
            ),
            body: Row(
              children: [
                RepaintBoundary(
                  child: ProfileRail(
                    controller: c,
                    activeAccent: widget.activeAccent,
                    onCreateCurrentSetup: c.createProfileFromCurrentSetup,
                  ),
                ),
                Expanded(
                  child: Stack(
                    children: [
                      // Static backdrop in its own layer — never repaints
                      // while monitors are dragged.
                      Positioned.fill(
                        child: RepaintBoundary(
                          child: DotGridBackground(
                            accent: widget.activeAccent ??
                                Theme.of(context).colorScheme.primary,
                          ),
                        ),
                      ),
                      Positioned.fill(
                        child: Padding(
                          padding:
                              const EdgeInsets.only(top: EditorHeader.height),
                          child: RepaintBoundary(
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
                                  // scaleMonitor also nudges edge-snapped
                                  // neighbours so they stay flush; without
                                  // applying those movements live, sway is
                                  // left with the old positions and gaps
                                  // open up between monitors that the GUI
                                  // shows as touching.
                                  final pre = {
                                    for (final m in c.activeMonitors)
                                      m.id: m,
                                  };
                                  c.scaleMonitor(tile.id, s,
                                      committing: true);
                                  for (final m in c.activeMonitors) {
                                    final before = pre[m.id];
                                    if (before == null) continue;
                                    final changed = m.id == tile.id ||
                                        before.x != m.x ||
                                        before.y != m.y ||
                                        before.scale != m.scale;
                                    if (!changed) continue;
                                    final r = await c.pushLiveApply(m);
                                    if (!r.success) {
                                      _toast(r);
                                      break;
                                    }
                                  }
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
                                isSelected: tile.id == _selectedId,
                                onSelect: () =>
                                    setState(() => _selectedId = tile.id),
                              );
                            }),
                          ],
                        );
                      },
                            ),
                          ),
                        ),
                      ),
                      Positioned(
                        top: 0,
                        left: 0,
                        right: 0,
                        child: RepaintBoundary(
                          child: EditorHeader(
                            profileName: c.activeProfile?.name,
                            accent: widget.activeAccent ??
                                Theme.of(context).colorScheme.primary,
                            hasUnappliedEdits: c.hasUnappliedEdits,
                            showApply: c.supportsLiveApply && !c.liveApply,
                            onApply: () async =>
                                _toast(await c.reloadAndApply()),
                            onIdentify: c.identifyDisplays,
                            onSettings: () => Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                builder: (_) => SettingsPage(
                                  controller: c,
                                  settings: widget.settings,
                                  onAppearanceChanged:
                                      widget.onAppearanceChanged,
                                ),
                              ),
                            ),
                          ),
                          ),
                        ),
                        // One-click layout presets, floating at the bottom.
                        Positioned(
                          left: 0,
                          right: 0,
                          bottom: 18,
                          child: Center(
                            child: PresetsBar(
                              onExtend: () async =>
                                  _toast(await c.extendOutputs()),
                              onMirror: c.supportsMirror
                                  ? () async => _toast(await c.mirrorAll())
                                  : null,
                              outputIds: c.activeMonitors
                                  .map((m) => m.id)
                                  .toList(),
                              onUseOnly: (id) async =>
                                  _toast(await c.useOnlyOutput(id)),
                            ),
                          ),
                        ),
                        // Health warnings and layout drift no longer float
                        // over the canvas: they are levels of the single
                        // assurance line at the bottom of the window. Two
                        // banners stacked with a hardcoded 96px offset — and
                        // able to appear alongside the safety-net bar and two
                        // SnackBars — is what "not thought through" looked
                        // like from outside.
                      ],
                    ),
                  ),
                // Right-hand properties inspector for the selected output.
                if (_selectedId != null &&
                    c.activeMonitors.any((m) => m.id == _selectedId))
                  PropertiesInspector(
                    controller: c,
                    monitorId: _selectedId!,
                    mirrorEnabled:
                        c.supportsMirror && (_wlMirrorAvailable ?? false),
                    onClose: () => setState(() => _selectedId = null),
                    onResult: _toast,
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

