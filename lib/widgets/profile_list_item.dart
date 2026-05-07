// lib/widgets/profile_list_item.dart

import 'package:flutter/material.dart';
import 'package:kanshi_gui/models/profiles.dart';
import 'package:kanshi_gui/state/kanshi_controller.dart';

class ProfileListItem extends StatefulWidget {
  final Profile profile;
  final bool isActive;
  final VoidCallback onSelect;
  final Function(String) onNameChanged;
  final VoidCallback? onDelete;
  final bool exists;
  /// Background colour for the active row. Threaded from
  /// `main.dart` after reading `~/.config/sway/config` so the GUI's
  /// active-profile highlight matches the user's sway accent (the
  /// border colour around their focused window). Null falls back to
  /// the historical teal — used when sway isn't installed, when the
  /// config has no `client.focused` directive, or when reading fails
  /// for any other reason.
  final Color? activeAccent;
  /// Per-profile compatibility with the currently connected output
  /// set. Renders as a small coloured dot at the start of the row so
  /// the user can tell at a glance which profiles would auto-fire
  /// (full), are partially connected (partial) or unusable right
  /// now (none). Null hides the dot — used in tests / standalone
  /// rendering where no controller is present.
  final ProfileMatchInfo? matchInfo;

  const ProfileListItem({
    super.key,
    required this.profile,
    required this.isActive,
    required this.onSelect,
    required this.onNameChanged,
    required this.onDelete,
    required this.exists,
    this.activeAccent,
    this.matchInfo,
  });

  @override
  State<ProfileListItem> createState() => _ProfileListItemState();
}

class _ProfileListItemState extends State<ProfileListItem> {
  bool isEditing = false;
  late TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.profile.name);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Active row picks up the user's sway accent (typically the
    // border colour around their focused window). The teal fallback
    // matches what the app shipped before the accent reader existed.
    final accent = widget.activeAccent ?? Colors.teal.shade300;
    Color backgroundColor =
        widget.isActive ? accent : Colors.transparent;
    return Container(
      color: backgroundColor,
      child: ListTile(
        title: isEditing
            ? TextField(
                controller: _controller,
                autofocus: true,
                onSubmitted: (value) {
                  widget.onNameChanged(value);
                  setState(() {
                    isEditing = false;
                  });
                },
              )
            : Text(widget.profile.name),
        leading: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.matchInfo != null) ...[
              _MatchDot(info: widget.matchInfo!),
              const SizedBox(width: 8),
            ],
            IconButton(
              icon: const Icon(Icons.edit),
              tooltip: 'Edit name',
              onPressed: () {
                setState(() {
                  isEditing = true;
                });
              },
            ),
          ],
        ),
        trailing: widget.onDelete != null
            ? IconButton(
                icon: const Icon(Icons.delete),
                tooltip: 'Delete profile',
                onPressed: widget.onDelete,
              )
            : null,
        onTap: widget.onSelect,
      ),
    );
  }
}

/// Compatibility dot rendered at the start of each profile row. The
/// colour encodes status (full/partial/none); the tooltip spells out
/// the connected/missing breakdown so the user gets gradient
/// information on hover instead of just a binary green/grey.
///
/// Colour palette is intentionally muted (shade400 / shade600) — the
/// dot lives next to the active-row's sway-accent highlight, and
/// loud primaries fight that accent visually. We're conveying
/// information, not shouting.
class _MatchDot extends StatelessWidget {
  final ProfileMatchInfo info;
  const _MatchDot({required this.info});

  @override
  Widget build(BuildContext context) {
    final Color color;
    final String tooltip;
    switch (info.status) {
      case ProfileMatchStatus.full:
        color = Colors.green.shade400;
        tooltip = 'All ${info.matched} outputs connected';
        break;
      case ProfileMatchStatus.partial:
        final detail = info.missing.isEmpty
            ? '${info.matched} of ${info.profileEnabled} '
                'profile outputs claimed'
            : '${info.missing.join(", ")} missing';
        tooltip = '${info.matched} of ${info.profileEnabled} '
            'outputs connected — $detail';
        color = Colors.amber.shade400;
        break;
      case ProfileMatchStatus.none:
        color = Colors.grey.shade600;
        tooltip = info.profileEnabled == 0
            ? 'No enabled outputs in profile'
            : 'No matching output connected';
        break;
    }
    return Tooltip(
      message: tooltip,
      child: Container(
        width: 10,
        height: 10,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
        ),
      ),
    );
  }
}
