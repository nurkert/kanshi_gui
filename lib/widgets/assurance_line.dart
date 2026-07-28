import 'package:flutter/material.dart';
import 'package:kanshi_gui/design/theme_context.dart';
import 'package:kanshi_gui/design/tokens.dart';
import 'package:kanshi_gui/state/app_status.dart';

/// The one status surface: 36 px, pinned above the window's bottom edge,
/// always visible, never empty, strictly one message at a time.
///
/// It replaces four surfaces that could stack — the health banner, the drift
/// banner, the safety-net bar and the SnackBar sites — one of which was
/// positioned with `EditorHeader.height + 10 + 96` arithmetic.
///
/// The icon is not decoration. At [StatusLevel.settled] it renders
/// [AppStatus.assurance], which is a comparison that actually ran: a check
/// only appears once the config was written AND a live compositor confirmed
/// the layout matches AND something is running that will re-apply it at boot.
/// Anything less gets a weaker sentence and a plain dot.
class AssuranceLine extends StatelessWidget {
  final AppStatus status;

  /// Shown right-aligned in the resting state, e.g. "verified now".
  final String? trailingNote;

  const AssuranceLine({super.key, required this.status, this.trailingNote});

  static const double height = 36;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final (icon, tint) = _leading(c);

    return Material(
      color: c.surface,
      child: SizedBox(
        height: height,
        child: Row(
          children: [
            const SizedBox(width: 14),
            SizedBox(
              width: 18,
              child: icon,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 200),
                child: Text(
                  status.message,
                  key: ValueKey(status.message),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: T.label.copyWith(color: tint ?? c.textSecondary),
                ),
              ),
            ),
            if (status.hasAction)
              TextButton(
                onPressed: () => status.onAction!(),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                ),
                child: Text(status.actionLabel!),
              )
            else if (trailingNote != null &&
                status.level == StatusLevel.settled)
              Padding(
                padding: const EdgeInsets.only(right: 14),
                child: Text(
                  trailingNote!,
                  style: T.caption.copyWith(color: c.textTertiary),
                ),
              ),
            const SizedBox(width: 4),
          ],
        ),
      ),
    );
  }

  (Widget, Color?) _leading(AppColors c) {
    switch (status.level) {
      case StatusLevel.attention:
      case StatusLevel.decision:
        return (
          Icon(Icons.error_outline, size: 16, color: c.danger),
          c.danger,
        );
      case StatusLevel.working:
        return (
          const SizedBox(
            width: 13,
            height: 13,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          null,
        );
      case StatusLevel.settled:
        switch (status.assurance) {
          case AssuranceLevel.verified:
            return (
              Icon(Icons.check_circle_outline, size: 16, color: c.ok),
              null,
            );
          case AssuranceLevel.writtenOnly:
          case AssuranceLevel.written:
            // Deliberately NOT a check. The sentence next to it says what is
            // and is not known; a check here would be a small lie.
            return (
              Icon(Icons.circle, size: 9, color: c.textTertiary),
              null,
            );
          case AssuranceLevel.unknown:
            return (
              Icon(Icons.circle_outlined, size: 12, color: c.textTertiary),
              null,
            );
        }
    }
  }
}
