import 'package:flutter/material.dart';
import 'package:kanshi_gui/models/profiles.dart';

/// Widget showing a single profile with edit and delete controls.
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
    this.onDelete,
    required this.exists,
  }) : super(key: key);

  @override
  _ProfileListItemState createState() => _ProfileListItemState();
}

class _ProfileListItemState extends State<ProfileListItem> {
  bool _editing = false;
  late TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.profile.name);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bg = widget.isActive ? Colors.teal.shade300 : Colors.transparent;
    return Container(
      color: bg,
      child: ListTile(
        title:
            _editing
                ? TextField(
                  controller: _ctrl,
                  autofocus: true,
                  onSubmitted: (v) {
                    widget.onNameChanged(v);
                    setState(() => _editing = false);
                  },
                )
                : Text(widget.profile.name),
        leading: IconButton(
          icon: const Icon(Icons.edit),
          onPressed: () => setState(() => _editing = true),
        ),
        trailing:
            widget.onDelete != null
                ? IconButton(
                  icon: const Icon(Icons.delete),
                  onPressed: widget.onDelete,
                )
                : null,
        onTap: widget.onSelect,
      ),
    );
  }
}
