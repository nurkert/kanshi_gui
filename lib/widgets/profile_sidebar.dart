import 'package:flutter/material.dart';
import 'package:kanshi_gui/state/kanshi_controller.dart';
import 'package:kanshi_gui/widgets/profile_list_item.dart';

/// Left-hand profile list with rename/delete actions plus the "Create
/// Current Setup" button that appears when the live layout has no matching
/// profile.
class ProfileSidebar extends StatelessWidget {
  final KanshiController controller;
  final VoidCallback onCreateCurrentSetup;

  const ProfileSidebar({
    super.key,
    required this.controller,
    required this.onCreateCurrentSetup,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.grey[850],
      child: Column(
        children: [
          Expanded(
            child: ListView.builder(
              itemCount: controller.profiles.length,
              itemBuilder: (context, i) {
                return ProfileListItem(
                  profile: controller.profiles[i],
                  isActive: controller.activeProfileIndex == i,
                  onSelect: () => controller.setActiveProfile(i),
                  onNameChanged: (newName) {
                    final r = controller.renameProfile(i, newName);
                    if (!r.success && r.message != null) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text(r.message!)),
                      );
                    }
                  },
                  onDelete: () => controller.deleteProfile(i),
                  exists: true,
                );
              },
            ),
          ),
          if (_currentSetupMissing(controller))
            Padding(
              padding: const EdgeInsets.all(8.0),
              child: ElevatedButton(
                onPressed: onCreateCurrentSetup,
                child: const Text('Create Current Setup'),
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
