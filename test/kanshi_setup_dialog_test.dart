import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kanshi_gui/services/kanshi_autostart.dart';
import 'package:kanshi_gui/state/kanshi_controller.dart' show OpResult;
import 'package:kanshi_gui/widgets/kanshi_setup_dialog.dart';

/// "kanshi isn't running" used to open the general tips, which do not mention
/// kanshi. These pin that the dialog offers exactly one fitting step and shows
/// what it would write before writing it.
void main() {
  late List<String> calls;
  late OpResult startResult;
  late OpResult addResult;
  OpResult? closedWith;

  setUp(() {
    calls = [];
    startResult = const OpResult.ok('kanshi is running.');
    addResult = const OpResult.ok('Added.');
    closedWith = null;
  });

  Future<void> open(WidgetTester tester, KanshiSetupFacts facts) async {
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () async {
              closedWith = await KanshiSetupDialog.show(
                context,
                facts: facts,
                onStart: () async {
                  calls.add('start');
                  return startResult;
                },
                onAddToSway: () async {
                  calls.add('add');
                  return addResult;
                },
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  const swayLines = ['exec kanshi', 'exec_always kanshictl reload'];

  testWidgets('not installed: says how to install, offers nothing to run',
      (tester) async {
    await open(
        tester,
        const KanshiSetupFacts(
            installed: false,
            configExists: true,
            autostart: KanshiAutostart()));
    expect(find.textContaining('sudo apt install kanshi'), findsOneWidget);
    expect(find.text('Start kanshi now'), findsNothing);
    expect(find.text('Add and start'), findsNothing);
  });

  testWidgets('no config yet: nothing to start', (tester) async {
    await open(
        tester,
        const KanshiSetupFacts(
            installed: true,
            configExists: false,
            autostart: KanshiAutostart(),
            swayLines: swayLines,
            swayConfigWritable: true));
    expect(find.textContaining('Save a setup first'), findsOneWidget);
    expect(find.text('Start kanshi now'), findsNothing);
    expect(find.text('Add and start'), findsNothing);
  });

  testWidgets('already set up: names where, and only starts it',
      (tester) async {
    await open(
      tester,
      const KanshiSetupFacts(
        installed: true,
        configExists: true,
        autostart: KanshiAutostart(
          starters: [
            KanshiStarter(KanshiStartedBy.swayConfig,
                path: '/home/u/.config/sway/config', line: 72),
          ],
          swayConfigPath: '/home/u/.config/sway/config',
        ),
        swayLines: swayLines,
        swayConfigWritable: true,
      ),
    );
    expect(find.textContaining('/home/u/.config/sway/config, line 72'),
        findsOneWidget);
    expect(find.text('Add and start'), findsNothing);
    await tester.tap(find.text('Start kanshi now'));
    await tester.pumpAndSettle();
    expect(calls, ['start']);
    expect(closedWith?.success, isTrue);
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('started twice says so', (tester) async {
    await open(
      tester,
      const KanshiSetupFacts(
        installed: true,
        configExists: true,
        autostart: KanshiAutostart(starters: [
          KanshiStarter(KanshiStartedBy.swayConfig, path: '/c', line: 1),
          KanshiStarter(KanshiStartedBy.systemdUnit),
        ]),
      ),
    );
    expect(find.textContaining('started twice'), findsOneWidget);
  });

  testWidgets('nothing starts it: shows the lines before adding them',
      (tester) async {
    await open(
      tester,
      const KanshiSetupFacts(
        installed: true,
        configExists: true,
        autostart: KanshiAutostart(swayConfigPath: '/home/u/.config/sway/config'),
        swayLines: swayLines,
        swayConfigWritable: true,
      ),
    );
    expect(find.text(swayLines.join('\n')), findsOneWidget);
    expect(calls, isEmpty, reason: 'opening the dialog writes nothing');
    await tester.tap(find.text('Add and start'));
    await tester.pumpAndSettle();
    expect(calls, ['add']);
    expect(closedWith?.message, 'Added.');
  });

  testWidgets('a failure stays in the dialog and says why', (tester) async {
    addResult = const OpResult.err('Could not write /home/u/.config/sway/config.');
    await open(
      tester,
      const KanshiSetupFacts(
        installed: true,
        configExists: true,
        autostart: KanshiAutostart(swayConfigPath: '/home/u/.config/sway/config'),
        swayLines: swayLines,
        swayConfigWritable: true,
      ),
    );
    await tester.tap(find.text('Add and start'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text('Could not write /home/u/.config/sway/config.'),
        findsOneWidget);
  });

  testWidgets('a sway config it cannot write: the lines, but no Add',
      (tester) async {
    await open(
      tester,
      const KanshiSetupFacts(
        installed: true,
        configExists: true,
        autostart: KanshiAutostart(swayConfigPath: '/etc/sway/config'),
        swayLines: swayLines,
      ),
    );
    expect(find.text(swayLines.join('\n')), findsOneWidget);
    expect(find.text('Add and start'), findsNothing);
    expect(find.text('Start kanshi now'), findsOneWidget);
  });

  testWidgets('a sway config that could not be read is not "nothing found"',
      (tester) async {
    await open(
      tester,
      const KanshiSetupFacts(
        installed: true,
        configExists: true,
        autostart: KanshiAutostart(complete: false),
        swayLines: swayLines,
        swayConfigWritable: true,
      ),
    );
    expect(find.textContaining('could not be read'), findsOneWidget);
    expect(find.text('Add and start'), findsNothing);
  });
}
