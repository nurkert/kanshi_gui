import 'package:flutter/material.dart';
import 'package:kanshi_gui/services/app_settings.dart';
import 'package:kanshi_gui/state/kanshi_controller.dart';

/// Dedicated, scrollable settings screen that replaced the cramped gear
/// PopupMenu. All preferences live in `~/.config/kanshi-gui/settings.json`
/// (the kanshi config is untouched); mutating a control persists the
/// settings file and pushes the change into the live [KanshiController] so
/// most take effect immediately. Appearance changes call
/// [onAppearanceChanged] so the app shell (theme / accent) rebuilds.
class SettingsPage extends StatefulWidget {
  final KanshiController controller;
  final AppSettings settings;
  final VoidCallback? onAppearanceChanged;

  const SettingsPage({
    super.key,
    required this.controller,
    required this.settings,
    this.onAppearanceChanged,
  });

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  AppSettings get s => widget.settings;
  KanshiController get c => widget.controller;

  /// Preset accent swatches offered next to the "Auto" (Sway-derived)
  /// option. Stored as ARGB ints in the settings.
  static const _accentSwatches = <Color>[
    Color(0xFF26A69A), // teal (the historical fallback)
    Color(0xFF42A5F5), // blue
    Color(0xFF7E57C2), // purple
    Color(0xFFEF5350), // red
    Color(0xFFFFA726), // orange
    Color(0xFF66BB6A), // green
    Color(0xFFEC407A), // pink
  ];

  void _persist() {
    // Fire-and-forget: the atomic write is fast and the UI doesn't block.
    // ignore: discarded_futures
    s.save();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          _behaviorSection(),
          if (c.supportsWorkspaceManagement) _workspacesSection(),
          _layoutSection(),
          _appearanceSection(),
          if (c.supportsMirror) _mirrorSection(),
          _advancedSection(),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  // ── Sections ───────────────────────────────────────────────────────────

  Widget _behaviorSection() => _Section(
        title: 'Behavior',
        children: [
          SwitchListTile(
            title: const Text('Auto-switch profile on hotplug'),
            subtitle: const Text(
                'Switch to the matching profile when a known monitor set is '
                'plugged in.'),
            value: s.autoSwitchProfile,
            onChanged: (v) {
              s.autoSwitchProfile = v;
              _persist();
            },
          ),
          SwitchListTile(
            title: const Text('Hotplug notifications'),
            subtitle: const Text(
                'Show a toast when a monitor connects or disconnects.'),
            value: s.hotplugToasts,
            onChanged: (v) {
              s.hotplugToasts = v;
              _persist();
            },
          ),
          SwitchListTile(
            title: const Text('Profile match suggestions'),
            subtitle: const Text(
                'Suggest switching when the connected set matches another '
                'profile.'),
            value: s.profileSuggestionToasts,
            onChanged: (v) {
              s.profileSuggestionToasts = v;
              _persist();
            },
          ),
          SwitchListTile(
            title: const Text('Live apply'),
            subtitle: const Text(
                'Push changes to the compositor instantly as you make them '
                '(no Apply button). Turn off to stage changes behind Apply.'),
            value: s.liveApply,
            onChanged: (v) {
              s.liveApply = v;
              _persist();
              // ignore: discarded_futures
              c.setLiveApply(v);
            },
          ),
          if (!s.liveApply)
            SwitchListTile(
              title: const Text('Confirm layout applies (auto-revert)'),
              subtitle: const Text(
                  'After Apply, run a countdown and roll back automatically '
                  'unless you confirm. Off by default.'),
              value: s.autoRevertOnApply,
              onChanged: (v) {
                s.autoRevertOnApply = v;
                c.autoRevertOnApply = v;
                _persist();
              },
            ),
          SwitchListTile(
            title: const Text('Auto re-apply on layout drift'),
            subtitle: const Text(
                'When a hotplug leaves the screens in the wrong position, '
                'silently run `kanshictl reload` to put them back. Off by '
                'default — the drift banner still offers a one-click fix.'),
            value: s.autoReapplyOnDrift,
            onChanged: (v) {
              s.autoReapplyOnDrift = v;
              c.setAutoReapplyOnDrift(v);
              _persist();
            },
          ),
          _SliderTile(
            title: 'Safety-net countdown',
            subtitle: 'Auto-revert a risky mode/disable change after this '
                'long. 0 disables the safety net.',
            value: s.safetyNetSeconds.toDouble(),
            min: 0,
            max: 60,
            divisions: 60,
            label: s.safetyNetSeconds == 0 ? 'Off' : '${s.safetyNetSeconds}s',
            onChanged: (v) {
              s.safetyNetSeconds = v.round();
              c.setSafetyNetSeconds(s.safetyNetSeconds);
              _persist();
            },
          ),
          _SliderTile(
            title: 'Custom-mode auto-revert',
            subtitle: 'How long a previewed custom mode waits before '
                'reverting if you don\'t keep it.',
            value: s.customModeRevertSeconds.toDouble(),
            min: 3,
            max: 60,
            divisions: 57,
            label: '${s.customModeRevertSeconds}s',
            onChanged: (v) {
              s.customModeRevertSeconds = v.round();
              c.setCustomModeRevertSeconds(s.customModeRevertSeconds);
              _persist();
            },
          ),
        ],
      );

  Widget _workspacesSection() {
    final mode = s.workspaceManagement;
    return _Section(
      title: 'Workspaces (Sway)',
      children: [
        SwitchListTile(
          title: const Text('Manage Sway workspaces'),
          subtitle: const Text(
              'Distribute workspaces 1–9 across your monitors on profile '
              'apply. Turning this on rearranges your current workspaces.'),
          value: mode.enabled,
          onChanged: (v) => _setWorkspaceMode(v
              ? WorkspaceManagementMode.interleaved
              : WorkspaceManagementMode.off),
        ),
        if (mode.enabled)
          Padding(
            padding: const EdgeInsets.only(left: 16, bottom: 8),
            child: RadioGroup<WorkspaceManagementMode>(
              groupValue: mode,
              onChanged: (m) {
                if (m != null) _setWorkspaceMode(m);
              },
              child: const Column(
                children: [
                  RadioListTile<WorkspaceManagementMode>(
                    title: Text('Interleaved'),
                    subtitle: Text('1/3/5… left, 2/4/6… right'),
                    value: WorkspaceManagementMode.interleaved,
                  ),
                  RadioListTile<WorkspaceManagementMode>(
                    title: Text('Grouped'),
                    subtitle: Text('1–5 left, 6–9 right (contiguous)'),
                    value: WorkspaceManagementMode.grouped,
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  void _setWorkspaceMode(WorkspaceManagementMode mode) {
    s.workspaceManagement = mode;
    _persist();
    // ignore: discarded_futures
    c.setWorkspaceDistribution(mode.distribution);
  }

  Widget _layoutSection() => _Section(
        title: 'Layout & editing',
        children: [
          _SliderTile(
            title: 'Snap distance',
            subtitle: 'How close an edge has to be before tiles snap '
                'together while dragging.',
            value: s.snapDistance.clamp(0, 200),
            min: 0,
            max: 200,
            divisions: 40,
            label: '${s.snapDistance.round()} px',
            onChanged: (v) {
              s.snapDistance = v;
              c.setSnapDistance(v);
              _persist();
            },
          ),
          SwitchListTile(
            title: const Text('Scale snapping'),
            subtitle: const Text(
                'Snap to common HiDPI scales (1.0, 1.25, 1.5…) on release.'),
            value: s.scaleSnapping,
            onChanged: (v) {
              s.scaleSnapping = v;
              c.setScaleSnapping(v);
              _persist();
            },
          ),
        ],
      );

  Widget _appearanceSection() => _Section(
        title: 'Appearance',
        children: [
          ListTile(
            title: const Text('Theme'),
            subtitle: const Text('Light, dark, or follow the system.'),
            trailing: SegmentedButton<AppThemeChoice>(
              segments: const [
                ButtonSegment(
                    value: AppThemeChoice.system, label: Text('System')),
                ButtonSegment(
                    value: AppThemeChoice.light, label: Text('Light')),
                ButtonSegment(value: AppThemeChoice.dark, label: Text('Dark')),
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
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Accent colour'),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    _accentChoice(
                      label: 'Auto',
                      selected: s.accentArgb == null,
                      color: null,
                      onTap: () {
                        s.accentArgb = null;
                        _persist();
                        widget.onAppearanceChanged?.call();
                      },
                    ),
                    for (final col in _accentSwatches)
                      _accentChoice(
                        label: '',
                        selected: s.accentArgb == col.toARGB32(),
                        color: col,
                        onTap: () {
                          s.accentArgb = col.toARGB32();
                          _persist();
                          widget.onAppearanceChanged?.call();
                        },
                      ),
                  ],
                ),
              ],
            ),
          ),
          _SliderTile(
            title: 'Identify banner duration',
            subtitle: 'How long the on-screen number banners stay up.',
            value: s.identifyBannerSeconds.toDouble(),
            min: 1,
            max: 10,
            divisions: 9,
            label: '${s.identifyBannerSeconds}s',
            onChanged: (v) {
              s.identifyBannerSeconds = v.round();
              c.setIdentifyBannerSeconds(s.identifyBannerSeconds);
              _persist();
            },
          ),
        ],
      );

  Widget _accentChoice({
    required String label,
    required bool selected,
    required Color? color,
    required VoidCallback onTap,
  }) {
    final border = selected
        ? Border.all(color: Theme.of(context).colorScheme.primary, width: 3)
        : Border.all(color: Colors.grey.withValues(alpha: 0.4));
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        width: 40,
        height: 40,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(8),
          border: border,
        ),
        child: color == null
            ? const Icon(Icons.auto_awesome, size: 18)
            : (selected ? const Icon(Icons.check, color: Colors.white) : null),
      ),
    );
  }

  Widget _mirrorSection() => _Section(
        title: 'Mirror (Sway)',
        children: [
          ListTile(
            title: const Text('Mirror scaling'),
            subtitle: const Text(
                'How wl-mirror fits the source onto a mirror destination.'),
            trailing: DropdownButton<MirrorScaling>(
              value: s.mirrorScaling,
              onChanged: (m) {
                if (m == null) return;
                s.mirrorScaling = m;
                _persist();
                // ignore: discarded_futures
                c.setMirrorScaling(m.arg);
              },
              items: const [
                DropdownMenuItem(
                    value: MirrorScaling.fit, child: Text('Fit (letterbox)')),
                DropdownMenuItem(
                    value: MirrorScaling.cover, child: Text('Cover (crop)')),
                DropdownMenuItem(
                    value: MirrorScaling.exact, child: Text('Exact (1:1)')),
              ],
            ),
          ),
        ],
      );

  Widget _advancedSection() => _Section(
        title: 'Advanced',
        children: [
          _SliderTile(
            title: 'Config backups kept',
            subtitle: 'How many timestamped kanshi-config backups to retain.',
            value: s.maxBackups.toDouble(),
            min: 1,
            max: 50,
            divisions: 49,
            label: '${s.maxBackups}',
            onChanged: (v) {
              s.maxBackups = v.round();
              c.setMaxBackups(s.maxBackups);
              _persist();
            },
          ),
          ListTile(
            title: const Text('kanshi config path'),
            subtitle: Text(
              s.kanshiConfigPath ?? '~/.config/kanshi/config (default)',
              style: const TextStyle(fontFamily: 'monospace'),
            ),
            trailing: const Icon(Icons.edit),
            onTap: _editConfigPath,
          ),
          ListTile(
            title: Text('Reset all settings to defaults',
                style: TextStyle(color: Theme.of(context).colorScheme.error)),
            leading: Icon(Icons.restore,
                color: Theme.of(context).colorScheme.error),
            onTap: _confirmReset,
          ),
        ],
      );

  Future<void> _editConfigPath() async {
    final ctl = TextEditingController(text: s.kanshiConfigPath ?? '');
    final result = await showDialog<String?>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('kanshi config path'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
                'Leave empty for the default. Takes effect after a restart.'),
            const SizedBox(height: 12),
            TextField(
              controller: ctl,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                hintText: '~/.config/kanshi/config',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, null),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctl.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    ctl.dispose();
    if (result == null) return;
    s.kanshiConfigPath = result.isEmpty ? null : result;
    _persist();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Config path saved — restart to apply.')),
      );
    }
  }

  Future<void> _confirmReset() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Reset settings?'),
        content: const Text(
            'This restores every preference to its default, including '
            'turning workspace management off. Your profiles and kanshi '
            'config are not touched.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Reset'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    s.resetToDefaults();
    // Re-apply everything to the live controller.
    c.applyStartupSettings(s);
    // ignore: discarded_futures
    c.setWorkspaceDistribution(s.workspaceManagement.distribution);
    _persist();
    widget.onAppearanceChanged?.call();
  }
}

/// A titled group of settings rendered as a card.
class _Section extends StatelessWidget {
  final String title;
  final List<Widget> children;
  const _Section({required this.title, required this.children});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: Card(
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
              child: Text(
                title.toUpperCase(),
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      color: Theme.of(context).colorScheme.primary,
                      letterSpacing: 0.8,
                    ),
              ),
            ),
            ...children,
          ],
        ),
      ),
    );
  }
}

/// A labelled slider row used for the numeric/duration settings.
class _SliderTile extends StatelessWidget {
  final String title;
  final String subtitle;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final String label;
  final ValueChanged<double> onChanged;

  const _SliderTile({
    required this.title,
    required this.subtitle,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.label,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Text(title,
                    style: Theme.of(context).textTheme.titleMedium),
              ),
              Text(label,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: Theme.of(context).colorScheme.primary,
                      )),
            ],
          ),
          Text(subtitle,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).hintColor,
                  )),
          Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            divisions: divisions,
            label: label,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }
}
