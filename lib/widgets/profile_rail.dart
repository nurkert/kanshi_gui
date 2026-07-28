import 'package:flutter/material.dart';
import 'package:kanshi_gui/state/kanshi_controller.dart';

/// Persistent, always-visible left rail listing the profiles. Replaces the
/// old slide-in sidebar — profiles stay in view, the active one is clearly
/// marked with an accent bar + glow, and rows reveal rename/delete on hover.
class ProfileRail extends StatelessWidget {
  final KanshiController controller;
  final VoidCallback onCreateCurrentSetup;
  final Color? activeAccent;
  static const double width = 248;

  const ProfileRail({
    super.key,
    required this.controller,
    required this.onCreateCurrentSetup,
    this.activeAccent,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final accent = activeAccent ?? scheme.primary;
    return Container(
      width: width,
      decoration: BoxDecoration(
        color: scheme.surface,
        border: Border(
          right: BorderSide(
            color: scheme.outlineVariant.withValues(alpha: 0.5),
          ),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Brand header.
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 22, 20, 14),
            child: Row(
              children: [
                Icon(Icons.dashboard_customize_rounded,
                    color: accent, size: 22),
                const SizedBox(width: 10),
                Text(
                  'kanshi_gui',
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.5,
                      ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Text(
              'PROFILES',
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                    letterSpacing: 1.2,
                  ),
            ),
          ),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              itemCount: controller.profiles.length,
              itemBuilder: (context, i) {
                return _ProfileCard(
                  key: ValueKey('profile-$i-${controller.profiles[i].name}'),
                  name: controller.profiles[i].name,
                  isActive: controller.activeProfileIndex == i,
                  accent: accent,
                  matchInfo: controller.profileMatchInfo(i),
                  onSelect: () => controller.setActiveProfile(i),
                  onRename: (newName) {
                    final r = controller.renameProfile(i, newName);
                    if (!r.success && r.message != null) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text(r.message!)),
                      );
                    }
                    return r.success;
                  },
                  onDelete: () => controller.deleteProfile(i),
                );
              },
            ),
          ),
          if (_currentSetupMissing(controller))
            Padding(
              padding: const EdgeInsets.all(12),
              child: FilledButton.tonalIcon(
                onPressed: onCreateCurrentSetup,
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Save current setup'),
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(44),
                ),
              ),
            ),
        ],
      ),
    );
  }

  bool _currentSetupMissing(KanshiController c) {
    final currentEnabled =
        c.currentMonitors.where((m) => m.enabled).toList();
    if (currentEnabled.isEmpty) return false;
    for (final p in c.profiles) {
      final enabled = p.monitors.where((m) => m.enabled).toList();
      if (enabled.length != currentEnabled.length) continue;
      final allMatch = currentEnabled.every((cm) => enabled.any((pm) =>
          pm.id.replaceAll(RegExp(r'\s+'), ' ').trim().toLowerCase() ==
              cm.id.replaceAll(RegExp(r'\s+'), ' ').trim().toLowerCase() ||
          pm.manufacturer
                  .replaceAll(RegExp(r'\s+'), ' ')
                  .trim()
                  .toLowerCase() ==
              cm.manufacturer
                  .replaceAll(RegExp(r'\s+'), ' ')
                  .trim()
                  .toLowerCase()));
      if (allMatch) return false;
    }
    return true;
  }
}

class _ProfileCard extends StatefulWidget {
  final String name;
  final bool isActive;
  final Color accent;
  final ProfileMatchInfo? matchInfo;
  final VoidCallback onSelect;
  /// Returns true when the rename was accepted. A rejected name (empty, a
  /// duplicate, one containing braces or control characters) keeps the field
  /// open so the user can correct it instead of silently losing the edit.
  final bool Function(String newName) onRename;
  final VoidCallback onDelete;

  const _ProfileCard({
    super.key,
    required this.name,
    required this.isActive,
    required this.accent,
    required this.matchInfo,
    required this.onSelect,
    required this.onRename,
    required this.onDelete,
  });

  @override
  State<_ProfileCard> createState() => _ProfileCardState();
}

class _ProfileCardState extends State<_ProfileCard> {
  bool _hovered = false;
  bool _editing = false;
  late final TextEditingController _ctl =
      TextEditingController(text: widget.name);

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  void _commitRename() {
    if (!widget.onRename(_ctl.text.trim())) return;
    setState(() => _editing = false);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final active = widget.isActive;
    final showActions = _hovered || active;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            color: active
                ? widget.accent.withValues(alpha: 0.16)
                : (_hovered
                    ? scheme.onSurface.withValues(alpha: 0.05)
                    : Colors.transparent),
            border: Border.all(
              color: active
                  ? widget.accent.withValues(alpha: 0.7)
                  : Colors.transparent,
            ),
            boxShadow: active
                ? [
                    BoxShadow(
                      color: widget.accent.withValues(alpha: 0.22),
                      blurRadius: 14,
                      spreadRadius: -4,
                    ),
                  ]
                : null,
          ),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: widget.onSelect,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 6, 10),
              child: Row(
                children: [
                  if (widget.matchInfo != null) ...[
                    _MatchDot(info: widget.matchInfo!),
                    const SizedBox(width: 10),
                  ],
                  Expanded(
                    child: _editing
                        ? TextField(
                            controller: _ctl,
                            autofocus: true,
                            decoration: const InputDecoration(
                              isDense: true,
                              border: OutlineInputBorder(),
                              contentPadding:
                                  EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                            ),
                            onSubmitted: (_) => _commitRename(),
                          )
                        : Text(
                            widget.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontWeight:
                                  active ? FontWeight.w700 : FontWeight.w500,
                              color: scheme.onSurface,
                            ),
                          ),
                  ),
                  // Fixed-width trailing area so hovering (which reveals the
                  // actions) never changes the row's size — no jitter.
                  SizedBox(
                    width: 72,
                    child: _editing
                        ? Align(
                            alignment: Alignment.centerRight,
                            child: IconButton(
                              icon: const Icon(Icons.check, size: 18),
                              visualDensity: VisualDensity.compact,
                              tooltip: 'Save name',
                              onPressed: _commitRename,
                            ),
                          )
                        : Visibility(
                            visible: showActions,
                            maintainSize: true,
                            maintainAnimation: true,
                            maintainState: true,
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              mainAxisAlignment: MainAxisAlignment.end,
                              children: [
                                IconButton(
                                  icon: const Icon(Icons.edit_outlined,
                                      size: 17),
                                  visualDensity: VisualDensity.compact,
                                  tooltip: 'Rename',
                                  onPressed: () => setState(() {
                                    _ctl.text = widget.name;
                                    _editing = true;
                                  }),
                                ),
                                IconButton(
                                  icon: const Icon(Icons.delete_outline,
                                      size: 17),
                                  visualDensity: VisualDensity.compact,
                                  tooltip: 'Delete',
                                  onPressed: widget.onDelete,
                                ),
                              ],
                            ),
                          ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Compatibility dot: green = all connected, amber = partial, grey = none.
class _MatchDot extends StatelessWidget {
  final ProfileMatchInfo info;
  const _MatchDot({required this.info});

  @override
  Widget build(BuildContext context) {
    final Color color;
    final String tooltip;
    switch (info.status) {
      case ProfileMatchStatus.full:
        color = const Color(0xFF34D399);
        tooltip = 'All ${info.matched} outputs connected';
        break;
      case ProfileMatchStatus.partial:
        color = const Color(0xFFFBBF24);
        tooltip = info.missing.isEmpty
            ? '${info.matched} of ${info.profileEnabled} outputs connected'
            : '${info.missing.join(", ")} missing';
        break;
      case ProfileMatchStatus.none:
        color = const Color(0xFF6B7280);
        tooltip = info.profileEnabled == 0
            ? 'No enabled outputs in profile'
            : 'No matching output connected';
        break;
    }
    return Tooltip(
      message: tooltip,
      child: Container(
        width: 9,
        height: 9,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(color: color.withValues(alpha: 0.6), blurRadius: 5),
          ],
        ),
      ),
    );
  }
}
