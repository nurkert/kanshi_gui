import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kanshi_gui/models/monitor_tile_data.dart';
import 'package:kanshi_gui/models/profiles.dart';
import 'package:kanshi_gui/services/config_service.dart';
import 'package:kanshi_gui/services/kanshi_config_writer.dart';
import 'package:kanshi_gui/state/kanshi_controller.dart';
import 'package:kanshi_gui/widgets/decision_card.dart';

import 'fakes/fake_mirror_runner.dart';
import 'fakes/fake_monitor_service.dart';

MonitorTileData _mon(String id, {double x = 0}) => MonitorTileData(
      id: id,
      manufacturer: id,
      x: x,
      y: 0,
      width: 1920,
      height: 1080,
      rotation: 0,
      refresh: 60,
      resolution: '1920x1080',
      orientation: 'landscape',
    );

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('kanshi_dc_'));
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  /// Controller setup does real file and process I/O. `testWidgets` runs in
  /// FakeAsync, where those futures never complete, so every caller wraps
  /// this in `tester.runAsync`. This is why the project had no widget tests
  /// touching the controller until now.
  Future<KanshiController> build(FakeMonitorService fake) async {
    final cfg = ConfigService(
      configPath: '${tmp.path}/config',
      backupPrefix: '${tmp.path}/backups/config.bak',
      writeOptions: KanshiWriteOptions.neutral,
    );
    await cfg.saveProfiles([
      Profile(name: 'Desk', monitors: [_mon('A'), _mon('B', x: 1920)]),
    ]);
    final c = KanshiController(
      monitors: fake,
      config: cfg,
      mirrorRunner: FakeMirrorRunner(),
    );
    await c.init();
    return c;
  }

  Future<void> pumpCard(WidgetTester tester, KanshiController c) =>
      tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Stack(children: [DecisionCard(controller: c)]),
        ),
      ));

  testWidgets('nothing is shown while no guard is armed', (tester) async {
    final c = (await tester.runAsync(
        () => build(FakeMonitorService(outputs: [_mon('A')]))))!;
    await pumpCard(tester, c);
    expect(find.text('Can you read this?'), findsNothing);
    c.dispose();
  });

  testWidgets('an armed guard asks a question the user must answer',
      (tester) async {
    final fake =
        FakeMonitorService(outputs: [_mon('A'), _mon('B', x: 1920)]);
    final c = (await tester.runAsync(() => build(fake)))!;
    await tester.runAsync(() => c.safetyNet.guard(
          key: 'k',
          label: 'Dell U2720Q is now 3840 x 2160',
          doIt: () async {},
          revert: () async {},
        ));
    await pumpCard(tester, c);

    expect(find.text('Can you read this?'), findsOneWidget);
    expect(find.textContaining('puts itself back'), findsOneWidget);
    expect(find.text('Keep it'), findsOneWidget);
    expect(find.text('Put it back'), findsOneWidget);
    expect(find.textContaining('Enter keeps'), findsOneWidget);
    c.dispose();
  });

  testWidgets('Enter keeps and Escape reverts; nothing else answers',
      (tester) async {
    final c = (await tester.runAsync(
        () => build(FakeMonitorService(outputs: [_mon('A')]))))!;
    var reverted = false;
    await tester.runAsync(() => c.safetyNet.guard(
          key: 'k',
          label: 'Mode change on A',
          doIt: () async {},
          revert: () async => reverted = true,
        ));
    await pumpCard(tester, c);

    // A click on the scrim must NOT confirm: that would silently keep a
    // change that blacked out a screen the user was not looking at.
    await tester.tapAt(const Offset(10, 10));
    await tester.pump();
    expect(c.safetyNet.activePrompt, isNotNull);

    await tester.runAsync(() async {
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    });
    await tester.pump();
    expect(reverted, isTrue);
    expect(c.safetyNet.activePrompt, isNull);
    c.dispose();
  });

  testWidgets('Enter cements the change', (tester) async {
    final c = (await tester.runAsync(
        () => build(FakeMonitorService(outputs: [_mon('A')]))))!;
    var reverted = false;
    await tester.runAsync(() => c.safetyNet.guard(
          key: 'k',
          label: 'Mode change on A',
          doIt: () async {},
          revert: () async => reverted = true,
        ));
    await pumpCard(tester, c);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(c.safetyNet.activePrompt, isNull);
    expect(reverted, isFalse);
    c.dispose();
  });

  test('an armed guard is mirrored onto every connected output', () async {
    // The in-window card is not enough on its own: the window may be sitting
    // on the screen the change just blacked out.
    final fake =
        FakeMonitorService(outputs: [_mon('A'), _mon('B', x: 1920)]);
    final cfg = ConfigService(
      configPath: '${tmp.path}/config',
      backupPrefix: '${tmp.path}/backups/config.bak',
      writeOptions: KanshiWriteOptions.neutral,
    );
    await cfg.saveProfiles([
      Profile(name: 'Desk', monitors: [_mon('A'), _mon('B', x: 1920)]),
    ]);
    final c = KanshiController(
      monitors: fake,
      config: cfg,
      mirrorRunner: FakeMirrorRunner(),
    );
    await c.init();

    await c.safetyNet.guard(
      key: 'k',
      label: 'Mode change on A',
      doIt: () async {},
      revert: () async {},
    );
    expect(fake.safetyPrompts, hasLength(2));
    expect(fake.safetyPrompts.first, contains('Can you read this?'));

    c.safetyNet.confirm('k');
    c.dispose();
  });
}
