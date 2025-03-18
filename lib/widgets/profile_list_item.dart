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

  const ProfileListItem({
    Key? key,
    required this.profile,
    required this.isActive,
    required this.onSelect,
    required this.onNameChanged,
    required this.onDelete,
    required this.exists,
  }) : super(key: key);

  @override
  _ProfileListItemState createState() => _ProfileListItemState();
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
    Color baseColor = Colors.blue;
    Color tileColor = widget.isActive
        ? baseColor.withOpacity(0.5)
        : baseColor.withOpacity(0.2);

    return ListTile(
      tileColor: tileColor,
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
        tooltip: 'Namen bearbeiten',
        onPressed: () {
          setState(() {
            isEditing = true;
          });
        },
      ),
      trailing: IconButton(
        icon: const Icon(Icons.delete),
        tooltip: 'Profil löschen',
        onPressed: widget.onDelete,
      ),
      onTap: widget.onSelect,
    );
  }
}
