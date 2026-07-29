import 'package:flutter/material.dart';
import 'package:kanshi_gui/design/theme_context.dart';
import 'package:kanshi_gui/design/tokens.dart';
import 'package:kanshi_gui/state/kanshi_controller.dart';

/// The window's only chrome: which set of screens you are looking at, and
/// three controls.
///
/// Replaces a 248px permanent rail listing every profile. The rail was a
/// browser for something the user does not browse — the setup in play is
/// whichever screens are physically attached, decided by the hardware and by
/// kanshi, not by clicking a list. Putting the list behind the name gives a
/// quarter of the window back to the thing the app is actually about.
class SetupTitleBar extends StatelessWidget {
  final KanshiController controller;

  /// Opens the list of remembered setups.
  final VoidCallback onOpenSetups;
  final VoidCallback onIdentify;
  final VoidCallback onAdvanced;

  /// Shown only while live apply is off, which is the only state in which
  /// edits can be waiting for anything.
  final bool showApply;
  final VoidCallback onApply;

  const SetupTitleBar({
    super.key,
    required this.controller,
    required this.onOpenSetups,
    required this.onIdentify,
    required this.onAdvanced,
    required this.showApply,
    required this.onApply,
  });

  static const double height = Sp.titleBar;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final active = controller.activeProfile;
    final others = controller.profiles.length - (active == null ? 0 : 1);

    return Material(
      color: c.surface,
      child: Container(
        height: height,
        padding: const EdgeInsets.symmetric(horizontal: Sp.x4),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: c.hairline)),
        ),
        child: Row(
          children: [
            // Name plus chevron as ONE button with a real hit target — a bare
            // chevron is a 16px target for the most-used control in the bar.
            //
            // Expanded + Align rather than Flexible + Spacer: a Row splits its
            // free space BY FLEX, and a loose Flexible that shrink-wraps to a
            // short setup name does not hand its unused share back. With a
            // Spacer also claiming flex 1 the trailing controls could only ever
            // reach the middle of the bar, leaving a few hundred pixels dead at
            // the right edge on every launch.
            Expanded(
              child: Align(
                alignment: Alignment.centerLeft,
                child: InkWell(
                borderRadius: R.controlR,
                onTap: onOpenSetups,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: Sp.x2, vertical: Sp.x1),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              active?.name ?? 'No setup',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: T.title.copyWith(color: c.textPrimary),
                            ),
                            Text(
                              _subtitle(others),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: T.caption.copyWith(color: c.textTertiary),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: Sp.x1),
                      Icon(Icons.expand_more,
                          size: 18, color: c.textSecondary),
                    ],
                  ),
                ),
                ),
              ),
            ),
            if (showApply) ...[
              FilledButton.icon(
                onPressed: onApply,
                icon: const Icon(Icons.play_arrow_rounded, size: 18),
                label: const Text('Apply'),
              ),
              const SizedBox(width: Sp.x2),
            ],
            IconButton(
              tooltip: 'Flash a number on each screen',
              onPressed: onIdentify,
              icon: const Icon(Icons.lightbulb_outline, size: 20),
            ),
            IconButton(
              tooltip: 'Advanced',
              onPressed: onAdvanced,
              icon: const Icon(Icons.more_horiz, size: 20),
            ),
          ],
        ),
      ),
    );
  }

  String _subtitle(int others) {
    if (controller.hasUnappliedEdits) return 'Not applied yet';
    if (others <= 0) return 'Saved';
    return others == 1 ? '1 more setup remembered' : '$others more setups remembered';
  }
}

/// The remembered setups, as a list you rarely open.
///
/// Selecting one is deliberately a detour rather than the main way to use the
/// app: the setup in play is whichever screens are attached. This is for
/// renaming, deleting, and looking at a setup that is not currently connected.
class SetupsPopover extends StatelessWidget {
  final KanshiController controller;
  final VoidCallback onCreateFromCurrent;

  const SetupsPopover({
    super.key,
    required this.controller,
    required this.onCreateFromCurrent,
  });

  static Future<void> show(
    BuildContext context, {
    required KanshiController controller,
    required VoidCallback onCreateFromCurrent,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      builder: (_) => SetupsPopover(
        controller: controller,
        onCreateFromCurrent: onCreateFromCurrent,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return SafeArea(
      child: ListenableBuilder(
        listenable: controller,
        builder: (context, _) => Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(Sp.x6, Sp.x4, Sp.x6, Sp.x2),
              child: Text('Remembered setups',
                  style: T.heading.copyWith(color: c.textPrimary)),
            ),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: controller.profiles.length,
                itemBuilder: (context, i) {
                  final p = controller.profiles[i];
                  final isActive = controller.activeProfileIndex == i;
                  final match = controller.profileMatchInfo(i);
                  return ListTile(
                    selected: isActive,
                    leading: Icon(
                      isActive ? Icons.check_circle : Icons.circle_outlined,
                      size: 18,
                      color: isActive ? c.accent : c.textTertiary,
                    ),
                    title: Text(p.name),
                    subtitle: Text(_describe(p.monitors.length, match)),
                    // Words, not icons. A setup the app captured for the user
                    // is called "Setup 3" until they say otherwise, so the way
                    // to say otherwise cannot be something they have to guess
                    // — and a bare pencil next to a bare bin is two guesses.
                    // A popover has room for the two words that remove them.
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        TextButton(
                          onPressed: () => _rename(context, i, p.name),
                          child: const Text('Rename'),
                        ),
                        const SizedBox(width: Sp.x1),
                        TextButton(
                          onPressed: () => controller.deleteProfile(i),
                          child: const Text('Forget'),
                        ),
                      ],
                    ),
                    onTap: () {
                      controller.setActiveProfile(i);
                      Navigator.of(context).pop();
                    },
                  );
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(Sp.x4),
              child: FilledButton.icon(
                onPressed: () {
                  onCreateFromCurrent();
                  Navigator.of(context).pop();
                },
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Remember the screens I have now'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Asks for a new name for the setup at [index] and applies it.
  ///
  /// Renaming had no UI at all between M8 — which deleted the profile rail
  /// that used to carry it — and now, even though the controller could always
  /// do it. A setup captured for you is called `Setup 3` until you say
  /// otherwise, so being unable to say otherwise is not a small gap.
  Future<void> _rename(BuildContext context, int index, String current) async {
    final field = TextEditingController(text: current);
    // Selected rather than merely focused: the name being replaced is
    // usually a placeholder, and pre-selecting it means typing replaces it.
    field.selection =
        TextSelection(baseOffset: 0, extentOffset: current.length);
    final formKey = GlobalKey<FormState>();

    final name = await showDialog<String>(
      context: context,
      builder: (dialogContext) {
        void submit() {
          if (formKey.currentState?.validate() != true) return;
          Navigator.of(dialogContext).pop(field.text.trim());
        }

        return AlertDialog(
          title: const Text('Rename setup'),
          content: Form(
            key: formKey,
            child: TextFormField(
              controller: field,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Name'),
              // The same validator the controller enforces, so the reason a
              // name is refused arrives while it is being typed rather than
              // as a toast after the dialog has closed.
              validator: (v) =>
                  KanshiController.profileNameError(v ?? ''),
              onFieldSubmitted: (_) => submit(),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(onPressed: submit, child: const Text('Rename')),
          ],
        );
      },
    );
    field.dispose();
    if (name == null || name == current) return;

    final result = controller.renameProfile(index, name);
    // A duplicate name can only be caught against the profile list, so it
    // survives the field validator and has to be reported here.
    if (!result.success && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(result.message ?? 'Could not rename setup.')),
      );
    }
  }

  String _describe(int count, ProfileMatchInfo? match) {
    final screens = count == 1 ? '1 screen' : '$count screens';
    if (match == null) return screens;
    return switch (match.status) {
      ProfileMatchStatus.full => '$screens · all connected',
      ProfileMatchStatus.partial =>
        '$screens · ${match.matched} of ${match.profileEnabled} connected',
      ProfileMatchStatus.none => '$screens · not connected',
    };
  }
}
