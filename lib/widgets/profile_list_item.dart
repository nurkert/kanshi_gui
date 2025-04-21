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
    super.key,
    required this.profile,
    required this.isActive,
    required this.onSelect,
    required this.onNameChanged,
    required this.onDelete,
    required this.exists,
  });

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
    // Setze unterschiedliche Hintergrundfarben:
    Color backgroundColor = widget.isActive ? Colors.teal.shade300 : Colors.transparent;
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
