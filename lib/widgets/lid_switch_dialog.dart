import 'package:flutter/material.dart';
import 'package:kanshi_gui/design/theme_context.dart';
import 'package:kanshi_gui/design/tokens.dart';
import 'package:kanshi_gui/services/lid_switch.dart';
import 'package:kanshi_gui/state/kanshi_controller.dart' show OpResult;

/// What flipping the lid switch opens: the change to the sway config, shown
/// before it is made.
///
/// The lid rule needs two lines in a file the user owns. Nothing writes to
/// that file without showing what it will write, and a lid binding the user
/// already has is named, because the appended ones take its place.
class LidSwitchDialog extends StatefulWidget {
  /// Switching on (true) or off (false).
  final bool on;
  final LidSwitchFacts facts;
  final Future<OpResult> Function() onConfirm;

  const LidSwitchDialog({
    super.key,
    required this.on,
    required this.facts,
    required this.onConfirm,
  });

  /// Returns the result of the change, or null when the user backed out.
  static Future<OpResult?> show(
    BuildContext context, {
    required bool on,
    required LidSwitchFacts facts,
    required Future<OpResult> Function() onConfirm,
  }) =>
      showDialog<OpResult>(
        context: context,
        builder: (_) =>
            LidSwitchDialog(on: on, facts: facts, onConfirm: onConfirm),
      );

  @override
  State<LidSwitchDialog> createState() => _LidSwitchDialogState();
}

class _LidSwitchDialogState extends State<LidSwitchDialog> {
  bool _busy = false;
  String? _error;

  Future<void> _confirm() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final r = await widget.onConfirm();
    if (!mounted) return;
    if (r.success) {
      Navigator.of(context).pop(r);
      return;
    }
    setState(() {
      _busy = false;
      _error = r.message ?? 'That did not work.';
    });
  }

  @override
  Widget build(BuildContext context) {
    final col = context.colors;
    final f = widget.facts;
    final path = f.swayConfigPath;

    Widget p(String s) =>
        Text(s, style: T.body.copyWith(color: col.textSecondary));

    final body = <Widget>[];
    if (widget.on) {
      body.add(p('With the lid closed, the built-in screen is switched off '
          'while another screen is on, and its workspaces move over. It comes '
          'back on when the lid opens. A lid closed with no other screen '
          'leaves it on.'));
    }
    if (path == null) {
      body.add(p('No sway config was found, so there is nowhere to add the '
          'lid binding. This needs sway.'));
    } else if (f.scan == null) {
      body.add(p('$path could not be read, so it is not clear what it '
          'already says about the lid. Nothing was changed.'));
    } else if (!f.writable) {
      body.add(p('sway reads $path, which this app cannot change. '
          '${widget.on ? 'Adding' : 'Removing'} these lines by hand does the '
          'same:'));
      body.add(_code(col, LidSwitchBinding.lines));
    } else if (widget.on) {
      body.add(p('These lines go at the end of $path:'));
      body.add(_code(col, LidSwitchBinding.lines));
      final foreign = f.scan!.foreign;
      if (foreign.isNotEmpty) {
        body.add(p('Your config already says what the lid does. sway keeps '
            'the last binding, so these stop working while this is on:'));
        body.add(_code(col, [
          for (final l in foreign) '${l.text.trim()}    # line ${l.number}',
        ]));
      }
    } else {
      body.add(p('The lid lines come out of $path again, and the built-in '
          'screen is switched back on.'));
    }
    if (_error != null) {
      body.add(Text(_error!, style: T.body.copyWith(color: col.danger)));
    }

    return AlertDialog(
      title: Text(widget.on
          ? 'Switch the screen off with the lid?'
          : 'Stop switching the screen off with the lid?'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var i = 0; i < body.length; i++) ...[
              if (i > 0) const SizedBox(height: Sp.x3),
              body[i],
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: Text(f.canChange ? 'Cancel' : 'Close'),
        ),
        if (f.canChange)
          FilledButton(
            onPressed: _busy ? null : _confirm,
            child: Text(widget.on ? 'Add and switch on' : 'Remove'),
          ),
      ],
    );
  }

  Widget _code(AppColors col, List<String> lines) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(Sp.x3),
        decoration: BoxDecoration(
          color: col.surfaceRaised,
          borderRadius: R.cardR,
          border: Border.all(color: col.hairline),
        ),
        child: SelectableText(
          lines.join('\n'),
          style: T.mono.copyWith(color: col.textPrimary),
        ),
      );
}
