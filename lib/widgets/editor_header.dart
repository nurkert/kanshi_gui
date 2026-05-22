import 'package:flutter/material.dart';

/// Frosted top bar that floats over the editor canvas. Shows the active
/// profile name (with an "unapplied changes" dot) on the left and the canvas
/// actions on the right; the dot grid behind it shows through the blur for
/// the "dark editor" feel.
class EditorHeader extends StatelessWidget {
  static const double height = 60;

  final String? profileName;
  final Color accent;
  final bool hasUnappliedEdits;
  /// Whether to show the explicit Apply button. Hidden in live-apply mode
  /// (edits already reach the compositor instantly).
  final bool showApply;
  final VoidCallback onApply;
  final VoidCallback onIdentify;
  final VoidCallback onSettings;

  const EditorHeader({
    super.key,
    required this.profileName,
    required this.accent,
    required this.hasUnappliedEdits,
    required this.showApply,
    required this.onApply,
    required this.onIdentify,
    required this.onSettings,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
          height: height,
          padding: const EdgeInsets.symmetric(horizontal: 18),
          decoration: BoxDecoration(
            color: const Color(0xFF14171C).withValues(alpha: 0.92),
            border: Border(
              bottom: BorderSide(
                color: Colors.white.withValues(alpha: 0.08),
              ),
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 9,
                height: 9,
                decoration: BoxDecoration(
                  color: accent,
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                        color: accent.withValues(alpha: 0.7), blurRadius: 7),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Flexible(
                child: Text(
                  profileName ?? 'No profile',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.2,
                  ),
                ),
              ),
              if (hasUnappliedEdits) ...[
                const SizedBox(width: 10),
                _UnappliedChip(),
              ],
              const Spacer(),
              if (showApply) ...[
                FilledButton.icon(
                  onPressed: onApply,
                  icon: const Icon(Icons.check, size: 18),
                  label: const Text('Apply'),
                  style: FilledButton.styleFrom(
                    backgroundColor:
                        hasUnappliedEdits ? accent : null,
                    foregroundColor: hasUnappliedEdits ? Colors.black : null,
                  ),
                ),
                const SizedBox(width: 6),
              ],
              _HeaderAction(
                icon: Icons.lightbulb_outline,
                tooltip: 'Identify displays',
                onPressed: onIdentify,
              ),
              _HeaderAction(
                icon: Icons.settings,
                tooltip: 'Settings',
                onPressed: onSettings,
              ),
            ],
          ),
        );
  }
}

class _UnappliedChip extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.amber.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.amber.withValues(alpha: 0.5)),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.fiber_manual_record, size: 9, color: Colors.amber),
          SizedBox(width: 5),
          Text('unapplied',
              style: TextStyle(
                  color: Colors.amber,
                  fontSize: 11,
                  fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

class _HeaderAction extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;
  const _HeaderAction({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: Icon(icon, size: 20),
      tooltip: tooltip,
      color: Colors.white.withValues(alpha: 0.85),
      onPressed: onPressed,
    );
  }
}
