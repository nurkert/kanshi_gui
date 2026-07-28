import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kanshi_gui/state/app_status.dart';
import 'package:kanshi_gui/widgets/assurance_line.dart';

/// The first widget tests in the project: until v2.0 roughly 4,000 lines of
/// UI produced no coverage entries at all.
///
/// The assurance line is the right place to start, because its whole point is
/// that it must not overstate what the app knows.
Future<void> _pump(WidgetTester tester, AppStatus status,
    {String? trailingNote}) {
  return tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: const SizedBox.shrink(),
      bottomNavigationBar:
          AssuranceLine(status: status, trailingNote: trailingNote),
    ),
  ));
}

void main() {
  testWidgets('a verified save is the only state that gets a check',
      (tester) async {
    await _pump(tester, AppStatus.settled(AssuranceLevel.verified,
        screenCount: 2));
    expect(find.text('Saved. These 2 screens come back exactly like this.'),
        findsOneWidget);
    expect(find.byIcon(Icons.check_circle_outline), findsOneWidget);
  });

  testWidgets('without a live compositor the promise is explicitly narrower',
      (tester) async {
    await _pump(tester, AppStatus.settled(AssuranceLevel.writtenOnly));
    expect(find.byIcon(Icons.check_circle_outline), findsNothing,
        reason: 'a check here would claim something that was never checked');
    expect(
      find.textContaining("can't see your screens"),
      findsOneWidget,
    );
  });

  testWidgets('an unconfirmed save says so instead of going quiet',
      (tester) async {
    await _pump(tester, AppStatus.settled(AssuranceLevel.written));
    expect(find.byIcon(Icons.check_circle_outline), findsNothing);
    expect(find.textContaining('could not confirm'), findsOneWidget);
  });

  testWidgets('singular and plural read naturally', (tester) async {
    await _pump(tester,
        AppStatus.settled(AssuranceLevel.verified, screenCount: 1));
    expect(find.text('Saved. This screen comes back exactly like this.'),
        findsOneWidget);
  });

  testWidgets('an attention state carries exactly one action', (tester) async {
    var tapped = 0;
    await _pump(
      tester,
      AppStatus(
        level: StatusLevel.attention,
        message: 'A screen is not where you put it.',
        actionLabel: 'Put back',
        onAction: () => tapped++,
      ),
    );
    expect(find.text('A screen is not where you put it.'), findsOneWidget);
    expect(find.byType(TextButton), findsOneWidget);
    await tester.tap(find.text('Put back'));
    expect(tapped, 1);
  });

  testWidgets('the trailing note is suppressed while something needs action',
      (tester) async {
    await _pump(
      tester,
      AppStatus(
        level: StatusLevel.attention,
        message: 'kanshi is not running.',
        actionLabel: 'Details',
        onAction: () {},
      ),
      trailingNote: 'verified',
    );
    expect(find.text('verified'), findsNothing);
  });

  testWidgets('working shows a spinner and no icon', (tester) async {
    await _pump(
      tester,
      const AppStatus(level: StatusLevel.working, message: 'Applying…'),
    );
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.byIcon(Icons.check_circle_outline), findsNothing);
  });

  testWidgets('the line keeps a fixed height so nothing below it shifts',
      (tester) async {
    await _pump(tester, AppStatus.settled(AssuranceLevel.verified));
    expect(tester.getSize(find.byType(AssuranceLine)).height,
        AssuranceLine.height);
  });

  group('StatusCenter', () {
    test('a transient message decays back to the resting state', () async {
      final centre = StatusCenter();
      centre.setResting(AppStatus.settled(AssuranceLevel.verified));
      centre.show(const AppStatus(
        level: StatusLevel.settled,
        message: 'Moved Dell U2720Q back.',
        life: Duration(milliseconds: 60),
      ));
      expect(centre.status.message, 'Moved Dell U2720Q back.');
      await Future<void>.delayed(const Duration(milliseconds: 140));
      expect(centre.status.assurance, AssuranceLevel.verified);
      centre.dispose();
    });

    test('a newer message cancels the older decay', () async {
      final centre = StatusCenter();
      centre.setResting(AppStatus.settled(AssuranceLevel.verified));
      centre.show(const AppStatus(
          level: StatusLevel.settled,
          message: 'first',
          life: Duration(milliseconds: 60)));
      centre.show(const AppStatus(
          level: StatusLevel.attention, message: 'second'));
      await Future<void>.delayed(const Duration(milliseconds: 140));
      expect(centre.status.message, 'second',
          reason: 'the first message must not decay over the second');
      centre.dispose();
    });
  });
}
