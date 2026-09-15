import 'package:flutter/material.dart';
import 'package:kanshi_gui/design/theme_context.dart';
import 'package:kanshi_gui/design/tokens.dart';
import 'package:kanshi_gui/services/kanshi_autostart.dart';
import 'package:kanshi_gui/state/kanshi_controller.dart' show OpResult;

/// What "kanshi isn't running" opens.
///
/// That line used to open the general tips, which do not mention kanshi. The
/// user was told something was wrong and then shown three hints about custom
/// modes. This says what kanshi is for, what (if anything) is set up to start
/// it, and offers the one step that fits — never more than one change, and
/// never without showing what it will write.
class KanshiSetupDialog extends StatefulWidget {
  final KanshiSetupFacts facts;
  final Future<OpResult> Function() onStart;
  final Future<OpResult> Function() onAddToSway;

  const KanshiSetupDialog({
    super.key,
    required this.facts,
    required this.onStart,
    required this.onAddToSway,
  });

  /// Returns the result of whatever the user did, or null when they closed it.
  static Future<OpResult?> show(
    BuildContext context, {
    required KanshiSetupFacts facts,
    required Future<OpResult> Function() onStart,
    required Future<OpResult> Function() onAddToSway,
  }) =>
      showDialog<OpResult>(
        context: context,
        builder: (_) => KanshiSetupDialog(
          facts: facts,
          onStart: onStart,
          onAddToSway: onAddToSway,
        ),
      );

  @override
  State<KanshiSetupDialog> createState() => _KanshiSetupDialogState();
}

class _KanshiSetupDialogState extends State<KanshiSetupDialog> {
  bool _busy = false;
  String? _error;

  Future<void> _run(Future<OpResult> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final r = await action();
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
    final a = f.autostart;

    Widget p(String s) =>
        Text(s, style: T.body.copyWith(color: col.textSecondary));

    final body = <Widget>[
      p('kanshi applies your setups: when you log in, and whenever a screen '
          'is plugged in or out. This app writes its config; while kanshi is '
          'not running, nothing reads it.'),
    ];
    final actions = <Widget>[
      TextButton(
        onPressed: _busy ? null : () => Navigator.of(context).pop(),
        child: const Text('Close'),
      ),
    ];
    Widget start({required bool primary}) {
      final onPressed = _busy ? null : () => _run(widget.onStart);
      const label = Text('Start kanshi now');
      return primary
          ? FilledButton(onPressed: onPressed, child: label)
          : TextButton(onPressed: onPressed, child: label);
    }

    final swayPath = a.swayConfigPath;
    final lines = f.swayLines;
    if (!f.installed) {
      body.add(p('kanshi is not installed. Install it with your package '
          'manager — on Debian and Ubuntu: sudo apt install kanshi'));
    } else if (!f.configExists) {
      body.add(p('There is no kanshi config yet, and kanshi will not start '
          'without one. Save a setup first.'));
    } else if (a.found) {
      final s = a.starters.first;
      final where = s.by == KanshiStartedBy.swayConfig
          ? 'from ${s.path}, line ${s.line}'
          : 'by the kanshi.service user unit';
      body.add(p('It is set to start $where, but it is not running now. It '
          'may have exited — for example over a config it could not read.'));
      if (a.startedTwice) {
        body.add(p('It is started twice: from the sway config and by '
            'kanshi.service. Two copies apply setups over each other; keep '
            'one of them.'));
      }
      actions.add(start(primary: true));
    } else if (a.complete && swayPath != null && lines != null) {
      body.add(p(f.swayConfigWritable
          ? 'Nothing starts it when you log in. These lines, added at the end '
              'of $swayPath, start it with sway and re-apply your screens '
              'after a sway reload:'
          : 'Nothing starts it when you log in. sway reads $swayPath, which '
              'this app cannot change. Adding these lines to your sway config '
              'starts kanshi with sway:'));
      body.add(_code(col, lines));
      if (f.swayConfigWritable) {
        actions.add(start(primary: false));
        actions.add(FilledButton(
          onPressed: _busy ? null : () => _run(widget.onAddToSway),
          child: const Text('Add and start'),
        ));
      } else {
        actions.add(start(primary: true));
      }
    } else {
      body.add(p(a.complete
          ? "Nothing was found that starts it when you log in. Start it from "
              "your compositor's startup — in sway, with an exec kanshi line "
              'in the config.'
          : 'The sway config could not be read, so it is not clear what '
              'starts kanshi.'));
      actions.add(start(primary: true));
    }
    if (_error != null) {
      body.add(Text(_error!, style: T.body.copyWith(color: col.danger)));
    }

    return AlertDialog(
      title: const Text("kanshi isn't running"),
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
      actions: actions,
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
