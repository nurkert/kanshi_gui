import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:kanshi_gui/state/kanshi_controller.dart';

/// The safety-net countdown, as a card over a dimmed canvas.
///
/// This is the only state that leaves the assurance line. The line is 36px
/// and sits at the bottom, which is the wrong shape and the wrong place for a
/// question the user must answer — especially when the reason they are being
/// asked is that a screen may have just gone black.
///
/// Enter keeps, Escape reverts, and nothing else does either: an irreversible
/// change is only kept if the user positively says so. A click elsewhere, a
/// focus change or a timeout must never stand in for that answer, because
/// each of them would silently confirm a change that blacked out a screen the
/// user was not looking at. The timeout always reverts.
class DecisionCard extends StatefulWidget {
  final KanshiController controller;
  const DecisionCard({super.key, required this.controller});

  @override
  State<DecisionCard> createState() => _DecisionCardState();
}

class _DecisionCardState extends State<DecisionCard> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    // The countdown is a clock, so it ticks linearly and often enough to read
    // as one. Only runs while a guard is armed.
    _ticker = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (mounted && widget.controller.safetyNet.activePrompt != null) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final net = widget.controller.safetyNet;
    final prompt = net.activePrompt;
    if (prompt == null) return const SizedBox.shrink();

    final remaining = prompt.remaining();
    final window = net.window;
    final progress = window.inMilliseconds == 0
        ? 0.0
        : (remaining.inMilliseconds / window.inMilliseconds).clamp(0.0, 1.0);
    final scheme = Theme.of(context).colorScheme;

    return Positioned.fill(
      child: Focus(
        autofocus: true,
        onKeyEvent: (node, event) {
          if (event is! KeyDownEvent) return KeyEventResult.ignored;
          if (event.logicalKey == LogicalKeyboardKey.enter ||
              event.logicalKey == LogicalKeyboardKey.numpadEnter) {
            net.confirm(prompt.key);
            return KeyEventResult.handled;
          }
          if (event.logicalKey == LogicalKeyboardKey.escape) {
            // ignore: discarded_futures
            net.revertNow(prompt.key);
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: Container(
          // Dimmed, not blocked: the user can still see what changed. There
          // is deliberately no onTap — clicking the scrim must not answer.
          color: Colors.black.withValues(alpha: 0.40),
          alignment: Alignment.center,
          child: Material(
            color: scheme.surfaceContainerHighest,
            elevation: 12,
            borderRadius: BorderRadius.circular(14),
            child: Container(
              width: 420,
              padding: const EdgeInsets.fromLTRB(24, 22, 24, 18),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Can you read this?',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w600,
                      color: scheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '${prompt.label}. If you can read this, it worked. '
                    'Otherwise it puts itself back in '
                    '${remaining.inSeconds} seconds.',
                    style: TextStyle(
                      fontSize: 14,
                      height: 1.35,
                      color: scheme.onSurface.withValues(alpha: 0.72),
                    ),
                  ),
                  const SizedBox(height: 16),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: LinearProgressIndicator(
                      value: progress,
                      minHeight: 4,
                      backgroundColor:
                          scheme.onSurface.withValues(alpha: 0.12),
                      color: const Color(0xFFE8A33D),
                    ),
                  ),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      // The keyboard hint lives on its own rather than inside
                      // the labels: at 420px the two buttons plus "(Enter)"
                      // and "(Esc)" overflowed the row by 187px, which the
                      // widget test caught on its first run.
                      Expanded(
                        child: Text(
                          'Enter keeps · Esc puts it back',
                          style: TextStyle(
                            fontSize: 12,
                            color: scheme.onSurface.withValues(alpha: 0.45),
                          ),
                        ),
                      ),
                      TextButton(
                        // ignore: discarded_futures
                        onPressed: () => net.revertNow(prompt.key),
                        child: const Text('Put it back'),
                      ),
                      const SizedBox(width: 8),
                      FilledButton(
                        onPressed: () => net.confirm(prompt.key),
                        child: const Text('Keep it'),
                      ),
                    ],
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
