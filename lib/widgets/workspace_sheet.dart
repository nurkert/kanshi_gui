import 'dart:async';

import 'package:flutter/material.dart';
import 'package:kanshi_gui/design/theme_context.dart';
import 'package:kanshi_gui/design/tokens.dart';
import 'package:kanshi_gui/models/monitor_tile_data.dart';
import 'package:kanshi_gui/services/app_settings.dart';
import 'package:kanshi_gui/services/workspace_daemon.dart';
import 'package:kanshi_gui/state/kanshi_controller.dart';

/// Where the number keys go.
///
/// The setting used to be a four-entry dropdown in Advanced with a line of
/// text under it spelling out the result. That is the wrong shape for this
/// question. Nobody wants to choose between "interleaved" and "grouped"; they
/// want workspace 9 to be on the right-hand screen, and the only way to answer
/// that is to show them the screens with the numbers sitting on them.
///
/// So the screens are the control. They keep the proportions and the
/// left-to-right order of the real desk, each carries the numbers that live on
/// it, and a number can be dragged from one to another. The patterns above are
/// shortcuts for arrangements people commonly want, not modes to understand
/// first — pick one and watch the numbers move.
class WorkspaceSheet extends StatefulWidget {
  final KanshiController controller;
  final AppSettings settings;

  /// Injectable so the widget tests can run without a systemd on the box.
  final WorkspaceDaemon daemon;

  const WorkspaceSheet({
    super.key,
    required this.controller,
    required this.settings,
    required this.daemon,
  });

  static Future<void> show(
    BuildContext context, {
    required KanshiController controller,
    required AppSettings settings,
    WorkspaceDaemon? daemon,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => WorkspaceSheet(
        controller: controller,
        settings: settings,
        daemon: daemon ?? const WorkspaceDaemon(),
      ),
    );
  }

  @override
  State<WorkspaceSheet> createState() => _WorkspaceSheetState();
}

class _WorkspaceSheetState extends State<WorkspaceSheet> {
  /// The pattern the sheet was opened in. Leaving it is what makes the note
  /// about sway's session-scoped bindings worth the words — before that, the
  /// user has been told nothing they need to act on.
  late final WorkspaceManagementMode _openedIn =
      widget.controller.workspaceMode;

  /// Non-null while a mode change or an assignment is in flight, so two taps
  /// in a row cannot interleave two config writes.
  Future<void>? _busy;

  WorkspaceDaemonState _daemon = WorkspaceDaemonState.unavailable;

  @override
  void initState() {
    super.initState();
    unawaited(_refreshDaemon());
  }

  Future<void> _refreshDaemon() async {
    final state = await widget.daemon.state();
    if (!mounted) return;
    setState(() => _daemon = state);
  }

  KanshiController get c => widget.controller;

  bool get _changed => c.workspaceMode != _openedIn;

  @override
  Widget build(BuildContext context) {
    final col = context.colors;
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.9,
        ),
        // The controller is the source of truth for the mode and the map;
        // rebuilding from it means a change applied from anywhere else (a
        // hotplug switching setups, the Advanced sheet) shows up here too.
        child: AnimatedBuilder(
          animation: c,
          builder: (context, _) => SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(Sp.x6, Sp.x4, Sp.x6, Sp.x6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                _header(col),
                const SizedBox(height: Sp.x6),
                // Off is not a fifth pattern — it is the app stepping out of
                // the way entirely. Dimming the body says that better than a
                // radio button in a row of four could.
                Opacity(
                  opacity: c.workspaceMode.enabled ? 1 : 0.38,
                  child: IgnorePointer(
                    ignoring: !c.workspaceMode.enabled,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _patterns(col),
                        const SizedBox(height: Sp.x4),
                        _screens(col),
                      ],
                    ),
                  ),
                ),
                if (_changed) ...[
                  const SizedBox(height: Sp.x3),
                  _sessionNote(col),
                ],
                const Divider(height: Sp.x8),
                _daemonRow(col),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ── Header ─────────────────────────────────────────────────────────────

  Widget _header(AppColors col) {
    final on = c.workspaceMode.enabled;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Workspaces',
                  style: T.title.copyWith(color: col.textPrimary)),
              const SizedBox(height: Sp.x1),
              Text(
                on
                    ? r'Where $mod+1 through $mod+9 take you.'
                    : r'sway decides where $mod+1 through $mod+9 take you.',
                style: T.caption.copyWith(color: col.textSecondary),
              ),
            ],
          ),
        ),
        Switch(
          value: on,
          onChanged: _busy != null
              ? null
              : (v) => _run(_setMode(
                    v ? WorkspaceManagementMode.interleaved
                      : WorkspaceManagementMode.off,
                  )),
        ),
      ],
    );
  }

  // ── Patterns ───────────────────────────────────────────────────────────

  static const _patternLabels = <WorkspaceManagementMode, String>{
    WorkspaceManagementMode.interleaved: 'Left to right',
    WorkspaceManagementMode.grouped: 'A block per screen',
    WorkspaceManagementMode.learned: 'Where they are now',
    WorkspaceManagementMode.custom: 'My own',
  };

  Widget _patterns(AppColors col) {
    final mode = c.workspaceMode;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Wrap(
          spacing: Sp.x2,
          runSpacing: Sp.x2,
          children: [
            for (final entry in _patternLabels.entries)
              ChoiceChip(
                label: Text(entry.value),
                labelStyle: T.label.copyWith(
                  color: mode == entry.key ? col.accent : col.textSecondary,
                ),
                selected: mode == entry.key,
                showCheckmark: false,
                backgroundColor: col.surfaceRaised,
                selectedColor: col.accentSoft,
                side: BorderSide(
                  color: mode == entry.key ? col.accent : col.hairline,
                ),
                shape: const RoundedRectangleBorder(borderRadius: R.chipR),
                onSelected: _busy != null
                    ? null
                    : (_) => _run(_setMode(entry.key)),
              ),
          ],
        ),
        const SizedBox(height: Sp.x2),
        Text(
          _patternCaption(mode),
          style: T.caption.copyWith(color: col.textTertiary),
        ),
      ],
    );
  }

  String _patternCaption(WorkspaceManagementMode mode) {
    switch (mode) {
      case WorkspaceManagementMode.off:
        return 'A new workspace opens on whichever screen you were last on.';
      case WorkspaceManagementMode.interleaved:
        return 'The numbers walk across the screens and start over: '
            '1 goes left, 2 to the next, and so on.';
      case WorkspaceManagementMode.grouped:
        return 'Each screen owns one run of consecutive numbers.';
      case WorkspaceManagementMode.learned:
        return 'Wherever you leave your workspaces is where they come back. '
            'Rearranging them by hand teaches this setup its new shape.';
      case WorkspaceManagementMode.custom:
        return 'Yours, one number at a time, for this set of screens.';
    }
  }

  // ── The screens ────────────────────────────────────────────────────────

  Widget _screens(AppColors col) {
    final ranked = c.workspaceScreens();
    final map = c.currentWorkspaceMap();
    if (ranked.isEmpty || map.isEmpty) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: Sp.x8),
        decoration: BoxDecoration(
          color: col.surface,
          borderRadius: R.screenR,
          border: Border.all(color: col.hairline),
        ),
        child: Text(
          'No screens to spread them across yet.',
          textAlign: TextAlign.center,
          style: T.caption.copyWith(color: col.textTertiary),
        ),
      );
    }

    final byId = {for (final m in _sourceMonitors()) m.id: m};
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        // Proportional widths, in rank order: the row is a plan of the desk,
        // so the screen on the left of the sheet is the screen on the left of
        // the desk. Flex on the logical width rather than equal thirds,
        // because "the wide one in the middle" is how people find their
        // screen in a picture of three rectangles.
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < ranked.length; i++) ...[
                if (i > 0) const SizedBox(width: Sp.x2),
                Expanded(
                  flex: _flexFor(byId[ranked[i].id]),
                  child: _ScreenDropTarget(
                    colors: col,
                    monitor: byId[ranked[i].id],
                    outputId: ranked[i].id,
                    workspaces: (map.entries
                        .where((e) => e.value == ranked[i].id)
                        .map((e) => e.key)
                        .toList()
                      ..sort()),
                    enabled: _busy == null,
                    onDropped: (ws) => _run(_assign(ws, ranked[i].id)),
                    onTapped: (ws) => _run(_assign(
                      ws,
                      ranked[(i + 1) % ranked.length].id,
                    )),
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: Sp.x2),
        Text(
          ranked.length == 1
              ? 'One screen, so every number lands on it.'
              : 'Drag a number onto another screen — or tap it to send it '
                  'one screen to the right.',
          style: T.caption.copyWith(color: col.textTertiary),
        ),
      ],
    );
  }

  List<MonitorTileData> _sourceMonitors() =>
      c.activeMonitors.isNotEmpty ? c.activeMonitors : c.currentMonitors;

  /// Flex weights are integers, and a screen must never collapse to nothing,
  /// so the logical width is floored at a readable minimum.
  int _flexFor(MonitorTileData? m) {
    if (m == null || m.scale <= 0) return 100;
    final logical = m.width / m.scale;
    if (!logical.isFinite || logical <= 0) return 100;
    return logical.round().clamp(60, 10000);
  }

  Widget _sessionNote(AppColors col) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline, size: 14, color: col.textTertiary),
          const SizedBox(width: Sp.x2),
          Expanded(
            child: Text(
              'Workspaces you have open move now. One that sway already '
              'pinned somewhere else this session follows after your next '
              'login.',
              style: T.caption.copyWith(color: col.textTertiary),
            ),
          ),
        ],
      );

  // ── The helper service ─────────────────────────────────────────────────

  Widget _daemonRow(AppColors col) {
    if (_daemon == WorkspaceDaemonState.unavailable) {
      return Text(
        'Placed while this window is open, and by kanshi on every dock.',
        style: T.caption.copyWith(color: col.textTertiary),
      );
    }
    final on = _daemon == WorkspaceDaemonState.enabled;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Keep this up with the app closed',
                  style: T.label.copyWith(color: col.textPrimary)),
              const SizedBox(height: Sp.x1),
              Text(
                on
                    ? 'A helper service places your workspaces at login, on '
                        'every dock, and as each one opens.'
                    : 'Without it, workspaces are placed when kanshi switches '
                        'setups and when you open this app — which is late, '
                        'on a cold boot.',
                style: T.caption.copyWith(color: col.textSecondary),
              ),
            ],
          ),
        ),
        const SizedBox(width: Sp.x4),
        Switch(
          value: on,
          onChanged: (v) => _run(_setDaemon(v)),
        ),
      ],
    );
  }

  // ── Actions ────────────────────────────────────────────────────────────

  /// Serialises the sheet's own writes and surfaces failures, so a refused
  /// `kanshictl reload` shows up here instead of leaving a control that
  /// silently disagrees with the config.
  void _run(Future<void> Function() action) {
    if (_busy != null) return;
    final future = () async {
      try {
        await action();
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('That did not stick: $e')),
        );
      }
    }();
    // A block body, not an arrow: `() => _busy = future` evaluates to the
    // assigned Future, and setState rejects a callback that returns one. It
    // throws out of the gesture handler, so the tap does nothing at all.
    setState(() {
      _busy = future;
    });
    unawaited(future.whenComplete(() {
      if (!mounted) return;
      setState(() {
        _busy = null;
      });
    }));
  }

  Future<void> Function() _setMode(WorkspaceManagementMode mode) => () async {
        if (mode == c.workspaceMode) return;
        widget.settings.workspaceManagement = mode;
        // The controller first: it is what actually places the workspaces, and
        // a settings.json that cannot be written must not stop that.
        await c.setWorkspaceMode(mode);
        await widget.settings.save();
      };

  /// The settings file is written BEFORE the config, not after it. Writing
  /// the config takes real I/O, and a settings.json that still said
  /// `interleaved` while the config already carried the user's hand-made map
  /// would let the rule win on the next launch and quietly discard the edit.
  Future<void> Function() _assign(int ws, String outputId) => () async {
        if (!c.canAssignWorkspace(ws, outputId)) return;
        widget.settings.workspaceManagement = WorkspaceManagementMode.custom;
        final saved = widget.settings.save();
        await c.assignWorkspace(ws, outputId);
        await saved;
      };

  Future<void> Function() _setDaemon(bool on) => () async {
        await widget.daemon.setEnabled(on);
        await _refreshDaemon();
      };
}

/// One screen in the plan: the numbers that live on it, its name, and a drop
/// target for numbers arriving from elsewhere.
class _ScreenDropTarget extends StatelessWidget {
  final AppColors colors;
  final MonitorTileData? monitor;
  final String outputId;
  final List<int> workspaces;
  final bool enabled;
  final ValueChanged<int> onDropped;
  final ValueChanged<int> onTapped;

  const _ScreenDropTarget({
    required this.colors,
    required this.monitor,
    required this.outputId,
    required this.workspaces,
    required this.enabled,
    required this.onDropped,
    required this.onTapped,
  });

  @override
  Widget build(BuildContext context) {
    return DragTarget<int>(
      onWillAcceptWithDetails: (d) =>
          enabled && !workspaces.contains(d.data),
      onAcceptWithDetails: (d) => onDropped(d.data),
      builder: (context, candidate, _) {
        final hot = candidate.isNotEmpty;
        return AnimatedContainer(
          duration: Motion.hover,
          constraints: const BoxConstraints(minHeight: 132),
          padding: const EdgeInsets.all(Sp.x3),
          decoration: BoxDecoration(
            color: hot ? colors.screenFillSelected : colors.screenFill,
            borderRadius: R.screenR,
            border: Border.all(
              color: hot ? colors.accent : colors.hairline,
              width: hot ? Borders.ring : Borders.hairline,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Expanded(
                child: workspaces.isEmpty
                    ? Align(
                        alignment: Alignment.topLeft,
                        child: Text('—',
                            style: T.label.copyWith(color: colors.textTertiary)),
                      )
                    : Align(
                        alignment: Alignment.topLeft,
                        child: Wrap(
                          spacing: Sp.x1,
                          runSpacing: Sp.x1,
                          children: [
                            for (final ws in workspaces)
                              _WorkspaceChip(
                                colors: colors,
                                number: ws,
                                enabled: enabled,
                                onTap: () => onTapped(ws),
                              ),
                          ],
                        ),
                      ),
              ),
              const SizedBox(height: Sp.x2),
              Text(
                _name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: T.label.copyWith(color: colors.textSecondary),
              ),
              Text(
                outputId,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: T.mono.copyWith(color: colors.textTertiary),
              ),
            ],
          ),
        );
      },
    );
  }

  /// The label without EDID's trailing model-code and serial, which is what
  /// the canvas tiles show too. The connector sits underneath in mono
  /// regardless — two panels of the same model carry the same name, and this
  /// sheet is precisely where telling them apart matters.
  String get _name {
    final label = monitor?.manufacturer ?? '';
    if (label.isEmpty) return outputId;
    final parts = label.split(' ');
    return parts.length > 2
        ? parts.sublist(0, parts.length - 2).join(' ')
        : label;
  }
}

/// One number key.
class _WorkspaceChip extends StatelessWidget {
  final AppColors colors;
  final int number;
  final bool enabled;
  final VoidCallback onTap;

  const _WorkspaceChip({
    required this.colors,
    required this.number,
    required this.enabled,
    required this.onTap,
  });

  static const double _size = 34;

  Widget _face({required Color fill, required Color border, required Color ink}) {
    return Container(
      width: _size,
      height: _size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: fill,
        borderRadius: R.chipR,
        border: Border.all(color: border),
      ),
      child: Text(
        '$number',
        style: T.label.copyWith(
          color: ink,
          fontWeight: FontWeight.w600,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final resting = _face(
      fill: colors.accentSoft,
      border: colors.accentLine,
      ink: colors.accent,
    );
    if (!enabled) return resting;
    return Tooltip(
      message: 'Workspace $number — tap to send it right, or drag it',
      waitDuration: const Duration(milliseconds: 600),
      child: Draggable<int>(
        data: number,
        dragAnchorStrategy: pointerDragAnchorStrategy,
        feedback: Material(
          type: MaterialType.transparency,
          child: _face(
            fill: colors.accent,
            border: colors.accent,
            ink: colors.bg,
          ),
        ),
        childWhenDragging: Opacity(opacity: 0.25, child: resting),
        child: InkWell(
          borderRadius: R.chipR,
          onTap: onTap,
          child: resting,
        ),
      ),
    );
  }
}
