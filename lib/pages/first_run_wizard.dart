import 'package:flutter/material.dart';
import 'package:kanshi_gui/services/app_settings.dart';
import 'package:kanshi_gui/services/profile_namer.dart';
import 'package:kanshi_gui/state/kanshi_controller.dart';

/// Three-step onboarding shown the first time the app starts. Detects the
/// active backend, lists the live outputs, suggests a profile name and —
/// on "Get started" — persists the suggestion as a profile and unsets the
/// first-run flag.
class FirstRunWizard extends StatefulWidget {
  final KanshiController controller;
  final AppSettings settings;
  final VoidCallback onDone;

  const FirstRunWizard({
    super.key,
    required this.controller,
    required this.settings,
    required this.onDone,
  });

  @override
  State<FirstRunWizard> createState() => _FirstRunWizardState();
}

class _FirstRunWizardState extends State<FirstRunWizard> {
  int _step = 0;
  late final TextEditingController _nameCtl;
  /// Opt-in choice for workspace management. Defaults to off so a user who
  /// clicks straight through the wizard never gets their workspaces moved.
  WorkspaceManagementMode _wsMode = WorkspaceManagementMode.off;
  /// The ordered step builders. The workspace step is only present on
  /// backends that can actually distribute workspaces (Sway); everywhere
  /// else the wizard is welcome → detected → confirm.
  late final List<Widget Function()> _steps;

  @override
  void initState() {
    super.initState();
    _nameCtl = TextEditingController(
      text: ProfileNamer.suggest(widget.controller.currentMonitors),
    );
    _steps = [
      _stepWelcome,
      _stepDetected,
      if (widget.controller.supportsWorkspaceManagement) _stepWorkspaces,
      _stepConfirm,
    ];
  }

  @override
  void dispose() {
    _nameCtl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Welcome to kanshi_gui')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: _steps[_step](),
      ),
    );
  }

  Widget _stepWelcome() {
    final backend = widget.controller.monitors.name;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('A graphical front-end for kanshi.',
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600)),
        const SizedBox(height: 12),
        Text('Detected compositor backend: $backend',
            style: const TextStyle(fontSize: 16)),
        const SizedBox(height: 4),
        Text(
          widget.controller.supportsLiveApply
              ? 'Live apply is available — drag a monitor and the change goes through immediately.'
              : 'No Wayland output tool detected — kanshi_gui will work as an offline profile editor.',
          style: const TextStyle(color: Colors.white70),
        ),
        const Spacer(),
        Align(
          alignment: Alignment.centerRight,
          child: FilledButton(
            onPressed: () => setState(() => _step++),
            child: const Text('Continue'),
          ),
        ),
      ],
    );
  }

  Widget _stepDetected() {
    final mons = widget.controller.currentMonitors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Detected outputs',
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600)),
        const SizedBox(height: 12),
        if (mons.isEmpty)
          const Text('No outputs reported by the compositor yet.')
        else
          Expanded(
            child: ListView(
              children: [
                for (final m in mons)
                  ListTile(
                    leading: Icon(
                      m.enabled
                          ? Icons.desktop_windows
                          : Icons.desktop_access_disabled,
                    ),
                    title: Text(m.id),
                    subtitle: Text(
                      '${m.manufacturer} • ${m.resolution}@${m.refresh.toStringAsFixed(0)}Hz',
                    ),
                  ),
              ],
            ),
          ),
        const SizedBox(height: 12),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            TextButton(
              onPressed: () => setState(() => _step--),
              child: const Text('Back'),
            ),
            FilledButton(
              onPressed: () => setState(() => _step++),
              child: const Text('Continue'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _stepWorkspaces() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Workspace management',
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600)),
        const SizedBox(height: 12),
        const Text(
          'kanshi_gui can spread your Sway workspaces (1–9) across your '
          'monitors whenever a profile is applied. This is optional — if '
          'you leave it off, kanshi_gui never touches your workspaces.',
          style: TextStyle(color: Colors.white70),
        ),
        const SizedBox(height: 16),
        Expanded(
          child: RadioGroup<WorkspaceManagementMode>(
            groupValue: _wsMode,
            onChanged: (m) => setState(() => _wsMode = m ?? _wsMode),
            child: ListView(
              children: const [
                RadioListTile<WorkspaceManagementMode>(
                  title: Text("Don't manage workspaces"),
                  subtitle: Text(
                      'Recommended — leaves your current setup untouched.'),
                  value: WorkspaceManagementMode.off,
                ),
                RadioListTile<WorkspaceManagementMode>(
                  title: Text('Interleaved'),
                  subtitle: Text(
                      'Workspaces 1/3/5… on the left screen, 2/4/6… on the '
                      'right.'),
                  value: WorkspaceManagementMode.interleaved,
                ),
                RadioListTile<WorkspaceManagementMode>(
                  title: Text('Grouped'),
                  subtitle: Text(
                      'Contiguous bands — e.g. 1–5 on the left, 6–9 on the '
                      'right.'),
                  value: WorkspaceManagementMode.grouped,
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            TextButton(
              onPressed: () => setState(() => _step--),
              child: const Text('Back'),
            ),
            FilledButton(
              onPressed: () => setState(() => _step++),
              child: const Text('Continue'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _stepConfirm() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Name your first profile',
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600)),
        const SizedBox(height: 12),
        const Text(
          'We picked a name based on your detected setup — feel free to change it.',
          style: TextStyle(color: Colors.white70),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _nameCtl,
          decoration: const InputDecoration(
            labelText: 'Profile name',
            border: OutlineInputBorder(),
          ),
        ),
        const Spacer(),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            TextButton(
              onPressed: () => setState(() => _step--),
              child: const Text('Back'),
            ),
            FilledButton(
              onPressed: _finish,
              child: const Text('Get started'),
            ),
          ],
        ),
      ],
    );
  }

  Future<void> _finish() async {
    final name = _nameCtl.text.trim();
    if (name.isEmpty) return;
    // Take the freshly created "Current Setup" (created during init) and
    // rename it. If for whatever reason it's not there, create one.
    final idx = widget.controller.profiles
        .indexWhere((p) => p.name == 'Current Setup');
    if (idx != -1) {
      widget.controller.renameProfile(idx, name);
    } else {
      widget.controller.createProfileFromCurrentSetup();
      final newIdx = widget.controller.profiles.length - 1;
      widget.controller.renameProfile(newIdx, name);
    }
    widget.settings.firstRunDone = true;
    widget.settings.workspaceManagement = _wsMode;
    await widget.settings.save();
    // Apply the workspace choice now so an opted-in user sees the
    // distribution take effect immediately (and the kanshi config gets the
    // exec line written). No-op when _wsMode is off.
    await widget.controller.setWorkspaceDistribution(_wsMode.distribution);
    widget.onDone();
  }
}
