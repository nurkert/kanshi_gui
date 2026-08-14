import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:kanshi_gui/design/theme_context.dart';
import 'package:kanshi_gui/design/tokens.dart';
import 'package:kanshi_gui/services/app_settings.dart';
import 'package:kanshi_gui/services/workspace_daemon.dart';
import 'package:kanshi_gui/state/kanshi_controller.dart';
import 'package:kanshi_gui/widgets/workspace_sheet.dart';

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

  /// Passed straight through to the Workspaces sheet; see [HomePage].
  final WorkspaceDaemon? workspaceDaemon;

  const AdvancedSheet({
    super.key,
    required this.controller,
    required this.settings,
    this.onAppearanceChanged,
    this.workspaceDaemon,
  });

  static Future<void> show(
    BuildContext context, {
    required KanshiController controller,
    required AppSettings settings,
    VoidCallback? onAppearanceChanged,
    WorkspaceDaemon? workspaceDaemon,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => AdvancedSheet(
        controller: controller,
        settings: settings,
        onAppearanceChanged: onAppearanceChanged,
        workspaceDaemon: workspaceDaemon,
      ),
    );
  }

  @override
  State<AdvancedSheet> createState() => _AdvancedSheetState();
}

class _AdvancedSheetState extends State<AdvancedSheet> {
  AppSettings get s => widget.settings;

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
                // A summary and a way through, not the control itself. The
                // control is a picture of the screens with the numbers on
                // them, which does not belong in a list of preferences — and
                // people who come looking for it here still find it.
                _row(
                  c,
                  label: 'Workspaces',
                  child: Text(
                    _workspacePreview(),
                    style: T.caption.copyWith(color: c.textSecondary),
                  ),
                  trailing: TextButton(
                    onPressed: () => WorkspaceSheet.show(
                      context,
                      controller: widget.controller,
                      settings: s,
                      daemon: widget.workspaceDaemon,
                    ),
                    child: const Text('Arrange'),
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

  /// Spells out where the numbers currently land on THESE screens, because
  /// the mode names describe a rule and the question people actually have is
  /// "where does $mod+9 take me".
  String _workspacePreview() {
    if (!widget.controller.workspaceMode.enabled) {
      return r'Your $mod+number keys are left to sway.';
    }
    final ranked = widget.controller.workspaceScreens();
    final map = widget.controller.currentWorkspaceMap();
    if (ranked.isEmpty || map.isEmpty) {
      return 'No screens to spread them across yet.';
    }
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
