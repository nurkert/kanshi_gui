import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:kanshi_gui/design/theme_context.dart';
import 'package:kanshi_gui/design/tokens.dart';
import 'package:kanshi_gui/domain/workspace_layout.dart';
import 'package:kanshi_gui/services/app_settings.dart';
import 'package:kanshi_gui/state/kanshi_controller.dart';

/// Everything the app still asks the user to decide, plus the facts it owes
/// them about where their config lives.
///
/// Replaces a 599-line settings screen with eighteen preferences. Twelve of
/// those were questions the app should answer itself — how close an edge has
/// to be before it snaps, how many seconds a countdown runs, whether to show
/// a toast — and each one was a decision pushed onto someone who opened this
/// app to move a screen. They are derived or fixed now; see PLAN-2.0.md 7.4.
///
/// A sheet rather than a page: settings are a detour, and a detour that
/// replaces the whole window makes the user find their way back.
class AdvancedSheet extends StatefulWidget {
  final KanshiController controller;
  final AppSettings settings;

  /// Called after a change that the app shell has to rebuild for.
  final VoidCallback? onAppearanceChanged;

  const AdvancedSheet({
    super.key,
    required this.controller,
    required this.settings,
    this.onAppearanceChanged,
  });

  static Future<void> show(
    BuildContext context, {
    required KanshiController controller,
    required AppSettings settings,
    VoidCallback? onAppearanceChanged,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => AdvancedSheet(
        controller: controller,
        settings: settings,
        onAppearanceChanged: onAppearanceChanged,
      ),
    );
  }

  @override
  State<AdvancedSheet> createState() => _AdvancedSheetState();
}

class _AdvancedSheetState extends State<AdvancedSheet> {
  AppSettings get s => widget.settings;

  /// True once the workspace mode was changed in this sheet, which is the
  /// only moment the sway caveat under the preview is worth the words.
  bool _workspaceModeChanged = false;

  void _persist() {
    unawaited(s.save().catchError((Object e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not save settings: $e')),
      );
    }));
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.8,
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(Sp.x6, Sp.x4, Sp.x6, Sp.x6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Advanced', style: T.title.copyWith(color: c.textPrimary)),
              const SizedBox(height: Sp.x1),
              Text(
                'kanshi_gui remembers every set of screens you use. Plug them '
                'in and they come back — even with this window closed, even '
                'right after you log in.',
                style: T.caption.copyWith(color: c.textSecondary),
              ),
              const SizedBox(height: Sp.x6),
              _row(
                c,
                label: 'Appearance',
                child: SegmentedButton<AppThemeChoice>(
                  segments: const [
                    ButtonSegment(
                        value: AppThemeChoice.system, label: Text('System')),
                    ButtonSegment(
                        value: AppThemeChoice.light, label: Text('Light')),
                    ButtonSegment(
                        value: AppThemeChoice.dark, label: Text('Dark')),
                  ],
                  selected: {s.themeChoice},
                  showSelectedIcon: false,
                  onSelectionChanged: (sel) {
                    s.themeChoice = sel.first;
                    _persist();
                    widget.onAppearanceChanged?.call();
                  },
                ),
              ),
              if (widget.controller.supportsWorkspaceManagement) ...[
                const SizedBox(height: Sp.x4),
                _row(
                  c,
                  label: 'Workspaces',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Read from the controller, not from settings: the
                      // controller is what actually decides where workspaces
                      // go, and if writing settings.json fails the control
                      // must still show the mode the app is in.
                      DropdownButton<WorkspaceManagementMode>(
                        value: widget.controller.workspaceMode,
                        isExpanded: true,
                        underline: const SizedBox.shrink(),
                        items: const [
                          DropdownMenuItem(
                            value: WorkspaceManagementMode.off,
                            child: Text('Leave them alone'),
                          ),
                          DropdownMenuItem(
                            value: WorkspaceManagementMode.interleaved,
                            child: Text('Number keys walk left to right'),
                          ),
                          DropdownMenuItem(
                            value: WorkspaceManagementMode.grouped,
                            child: Text('One block of numbers per screen'),
                          ),
                          DropdownMenuItem(
                            value: WorkspaceManagementMode.learned,
                            child: Text('Keep them where I put them'),
                          ),
                        ],
                        onChanged: (mode) =>
                            unawaited(_setWorkspaceMode(mode)),
                      ),
                      const SizedBox(height: Sp.x1),
                      Text(
                        _workspacePreview(),
                        style: T.caption.copyWith(color: c.textSecondary),
                      ),
                      // Only after a change, and only because sway cannot do
                      // what the line above promises within one session: it
                      // appends each workspace→output binding to a list and
                      // uses the first entry that resolves, so a workspace
                      // that already had a home keeps it. The ones that never
                      // had one — the reason this setting exists — move now.
                      if (_workspaceModeChanged) ...[
                        const SizedBox(height: Sp.x1),
                        Text(
                          'Workspaces you already have open move now. Any that '
                          'sway already placed elsewhere follow after your '
                          'next login.',
                          style: T.caption.copyWith(color: c.textTertiary),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
              const Divider(height: Sp.x8),
              _row(
                c,
                label: 'Config file',
                child: SelectableText(
                  widget.controller.config.configPath,
                  style: T.mono.copyWith(color: c.textSecondary),
                ),
                trailing: IconButton(
                  tooltip: 'Copy path',
                  icon: const Icon(Icons.copy_all_outlined, size: 18),
                  onPressed: () => Clipboard.setData(
                    ClipboardData(text: widget.controller.config.configPath),
                  ),
                ),
              ),
              const SizedBox(height: Sp.x4),
              _row(
                c,
                label: 'Earlier versions',
                child: Text(
                  'A copy of your config is kept before every change.',
                  style: T.caption.copyWith(color: c.textSecondary),
                ),
                trailing: TextButton(
                  onPressed: () async {
                    final r =
                        await widget.controller.restoreBackupAndApply();
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(r.message ?? 'Restored.')),
                    );
                  },
                  child: const Text('Restore the last one'),
                ),
              ),
              const Divider(height: Sp.x8),
              Text('How this works',
                  style: T.label.copyWith(color: c.textPrimary)),
              const SizedBox(height: Sp.x2),
              Text(
                'Your arrangement is stored as a kanshi profile, keyed by the '
                'displays themselves rather than by which port they happen to '
                'be plugged into — so it still matches after a reboot or a '
                'redock. kanshi applies it, with or without this window open.',
                style: T.caption.copyWith(color: c.textSecondary),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _setWorkspaceMode(WorkspaceManagementMode? mode) async {
    if (mode == null || mode == widget.controller.workspaceMode) return;
    _workspaceModeChanged = true;
    s.workspaceManagement = mode;
    _persist();
    try {
      await widget.controller.setWorkspaceMode(mode);
    } catch (e) {
      if (!mounted) return;
      setState(() {});
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not change workspace handling: $e')),
      );
      return;
    }
    if (mounted) setState(() {});
  }

  /// Spells out what the chosen mode does to THESE screens, because the
  /// mode names describe a rule and the question people actually have is
  /// "where does $mod+9 take me".
  String _workspacePreview() {
    final mode = widget.controller.workspaceMode;
    final distribution = mode.distribution;
    if (distribution == null) {
      return r'Your $mod+number keys are left to sway.';
    }
    final mons = [
      for (final m in widget.controller.activeMonitors.isNotEmpty
          ? widget.controller.activeMonitors
          : widget.controller.currentMonitors)
        if (m.enabled && m.mirrorOf == null) m,
    ];
    final ranked = resolveWorkspaceRanks(mons);
    if (ranked.isEmpty) return 'No screens to spread them across yet.';
    final map = resolveWorkspaceMap(
      ranked,
      distribution: distribution,
      learned: mode.learns ? widget.controller.activeProfile?.workspaceMap : null,
    );
    final perScreen = [
      for (final entry in ranked)
        (map.entries.where((e) => e.value == entry.id).map((e) => e.key).toList()
              ..sort())
            .join(' '),
    ];
    return 'Left to right: '
        '${perScreen.map((s) => s.isEmpty ? '—' : s).join('  ·  ')}';
  }

  Widget _row(
    AppColors c, {
    required String label,
    required Widget child,
    Widget? trailing,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 130,
          child: Padding(
            padding: const EdgeInsets.only(top: Sp.x1),
            child: Text(label, style: T.label.copyWith(color: c.textPrimary)),
          ),
        ),
        Expanded(child: child),
        if (trailing != null) trailing,
      ],
    );
  }
}
