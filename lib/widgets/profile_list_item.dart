// lib/widgets/profile_list_item.dart

import 'package:flutter/material.dart';
import 'package:kanshi_gui/models/profiles.dart';

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

  const ProfileListItem({
    super.key,
    required this.profile,
    required this.isActive,
    required this.onSelect,
    required this.onNameChanged,
    required this.onDelete,
    required this.exists,
    this.activeAccent,
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
        leading: IconButton(
          icon: const Icon(Icons.edit),
          tooltip: 'Edit name',
          onPressed: () {
            setState(() {
              isEditing = true;
            });
          },
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
