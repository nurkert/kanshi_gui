import 'dart:async';

import 'package:flutter/material.dart';
import 'package:kanshi_gui/state/kanshi_controller.dart';

/// Persistent bottom banner that shows the active SafetyNet prompt with a
/// countdown bar and Keep / Revert actions. Visible only while a guard is
/// armed; otherwise renders nothing.
class SafetyNetBanner extends StatefulWidget {
  final KanshiController controller;
  const SafetyNetBanner({super.key, required this.controller});

  @override
  State<SafetyNetBanner> createState() => _SafetyNetBannerState();
}

class _SafetyNetBannerState extends State<SafetyNetBanner> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final prompt = widget.controller.safetyNet.activePrompt;
    if (prompt == null) return const SizedBox.shrink();
    final remaining = prompt.remaining();
    final window = widget.controller.safetyNet.window;
    final progress =
        (remaining.inMilliseconds / window.inMilliseconds).clamp(0.0, 1.0);

    return Material(
      color: const Color(0xFF1F1F1F),
      elevation: 8,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Row(
          children: [
            const Icon(Icons.timer_outlined, color: Colors.amber),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${prompt.label} — reverting in ${remaining.inSeconds}s',
                    style: const TextStyle(
                        color: Colors.white, fontWeight: FontWeight.w500),
                  ),
                  const SizedBox(height: 6),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: progress,
                      minHeight: 4,
                      backgroundColor: Colors.white.withValues(alpha: 0.15),
                      color: Colors.amber,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            TextButton(
              onPressed: () =>
                  widget.controller.safetyNet.revertNow(prompt.key),
              style: TextButton.styleFrom(foregroundColor: Colors.orangeAccent),
              child: const Text('Revert'),
            ),
            const SizedBox(width: 4),
            FilledButton(
              onPressed: () =>
                  widget.controller.safetyNet.confirm(prompt.key),
              style: FilledButton.styleFrom(backgroundColor: Colors.green),
              child: const Text('Keep'),
            ),
          ],
        ),
      ),
    );
  }
}
