import 'dart:ui';

import 'package:flutter/material.dart';

/// A small frosted pill of one-click layout presets that floats at the
/// bottom of the canvas. Each preset only previews into the in-memory
/// layout (overlap-safe); the user still hits Apply to push it live.
class PresetsBar extends StatelessWidget {
  final VoidCallback onExtend;
  final VoidCallback? onMirror;
  /// Output ids offered in the "Single…" menu, in display order.
  final List<String> outputIds;
  final ValueChanged<String> onUseOnly;

  const PresetsBar({
    super.key,
    required this.onExtend,
    required this.onMirror,
    required this.outputIds,
    required this.onUseOnly,
  });

  @override
  Widget build(BuildContext context) {
    if (outputIds.isEmpty) return const SizedBox.shrink();
    return ClipRRect(
      borderRadius: BorderRadius.circular(28),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          decoration: BoxDecoration(
            color: const Color(0xFF14171C).withValues(alpha: 0.7),
            borderRadius: BorderRadius.circular(28),
            border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _PresetButton(
                icon: Icons.view_column_outlined,
                label: 'Extend',
                tooltip: 'Lay all outputs side by side',
                onPressed: onExtend,
              ),
              if (onMirror != null)
                _PresetButton(
                  icon: Icons.copy_all_outlined,
                  label: 'Mirror',
                  tooltip: 'Mirror everything onto the leftmost output',
                  onPressed: onMirror!,
                ),
              if (outputIds.length > 1)
                _SingleMenu(outputIds: outputIds, onUseOnly: onUseOnly),
            ],
          ),
        ),
      ),
    );
  }
}

class _PresetButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final String tooltip;
  final VoidCallback onPressed;
  const _PresetButton({
    required this.icon,
    required this.label,
    required this.tooltip,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: TextButton.icon(
        onPressed: onPressed,
        icon: Icon(icon, size: 18),
        label: Text(label),
        style: TextButton.styleFrom(
          foregroundColor: Colors.white.withValues(alpha: 0.9),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        ),
      ),
    );
  }
}

class _SingleMenu extends StatelessWidget {
  final List<String> outputIds;
  final ValueChanged<String> onUseOnly;
  const _SingleMenu({required this.outputIds, required this.onUseOnly});

  @override
  Widget build(BuildContext context) {
    return MenuAnchor(
      menuChildren: [
        for (final id in outputIds)
          MenuItemButton(
            onPressed: () => onUseOnly(id),
            leadingIcon: const Icon(Icons.desktop_windows, size: 16),
            child: Text('Only $id'),
          ),
      ],
      builder: (context, controller, _) => Tooltip(
        message: 'Use a single output, disable the rest',
        child: TextButton.icon(
          onPressed: () =>
              controller.isOpen ? controller.close() : controller.open(),
          icon: const Icon(Icons.crop_square, size: 18),
          label: const Text('Single'),
          style: TextButton.styleFrom(
            foregroundColor: Colors.white.withValues(alpha: 0.9),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          ),
        ),
      ),
    );
  }
}
