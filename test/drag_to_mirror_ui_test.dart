// Dragging one screen onto another, as the user sees it: the dragged tile
// stays on top, takes the other screen's place while hovering, and the drop
// asks which screen shows which.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kanshi_gui/models/monitor_tile_data.dart';
import 'package:kanshi_gui/models/profiles.dart';
import 'package:kanshi_gui/pages/home_page.dart';
import 'package:kanshi_gui/services/app_settings.dart';
import 'package:kanshi_gui/services/config_service.dart';
import 'package:kanshi_gui/services/kanshi_config_writer.dart';
import 'package:kanshi_gui/state/kanshi_controller.dart';
import 'package:kanshi_gui/widgets/monitor_tile.dart';

import 'fakes/fake_mirror_runner.dart';
import 'fakes/fake_monitor_service.dart';

MonitorTileData _mon(String id, double x) => MonitorTileData(
      id: id,
      manufacturer: id == 'eDP-1' ? 'InfoVision' : 'Samsung',
      x: x,
      y: 0,
      width: 1920,
      height: 1080,
      scale: 1.0,
      rotation: 0,
      refresh: 60,
      resolution: '1920x1080',
      orientation: 'landscape',
      enabled: true,
    );

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('kanshi_dragmirror_'));
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  testWidgets('the dragged screen rides on top and previews the mirror',
      (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    // Laptop LEFT of the television: in stack order the television used to
    // be painted over the laptop as soon as the laptop was dragged right.
    final mons = [_mon('eDP-1', 0), _mon('DP-1', 1920)];
    late KanshiController c;
    late AppSettings settings;
    await tester.runAsync(() async {
      final cfg = ConfigService(
        configPath: '${tmp.path}/config',
        backupPrefix: '${tmp.path}/backups/config.bak',
        writeOptions: KanshiWriteOptions.swayDefaults,
      );
      await cfg.saveProfiles([Profile(name: 'Talk', monitors: mons)]);
      c = KanshiController(
        monitors: FakeMonitorService(
          outputs: mons,
          supportsMirror: true,
          writeOptions: KanshiWriteOptions.swayDefaults,
        ),
        config: cfg,
        mirrorRunner: FakeMirrorRunner(),
      );
      await c.init();
      settings = AppSettings(filePath: '${tmp.path}/settings.json');
    });
    addTearDown(c.dispose);

    await tester.pumpWidget(
        MaterialApp(home: HomePage(controller: c, settings: settings)));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(seconds: 6));

    MonitorTile tileOf(String id) => tester.widget<MonitorTile>(
        find.byWidgetPredicate((w) => w is MonitorTile && w.data.id == id));
    List<String> stackOrder() => tester
        .widgetList<MonitorTile>(find.byType(MonitorTile))
        .map((t) => t.data.id)
        .toList();

    expect(stackOrder(), ['eDP-1', 'DP-1']);

    final laptopCenter = tester.getCenter(find.byWidgetPredicate(
        (w) => w is MonitorTile && w.data.id == 'eDP-1'));
    final tvCenter = tester.getCenter(find.byWidgetPredicate(
        (w) => w is MonitorTile && w.data.id == 'DP-1'));

    final gesture = await tester.startGesture(laptopCenter);
    // A first small move starts the drag; the tile must already be on top.
    await gesture.moveBy(const Offset(40, 0));
    await tester.pump();
    expect(stackOrder(), ['DP-1', 'eDP-1'],
        reason: 'the dragged screen paints above every other');
    expect(tileOf('eDP-1').mirrorPreviewRect, isNull,
        reason: 'a nudge is a move, not a mirror');

    // Over the television: the laptop's tile takes the television's place.
    await gesture.moveTo(tvCenter);
    await tester.pump();
    final tvRect = tester.getRect(find.byWidgetPredicate(
        (w) => w is MonitorTile && w.data.id == 'DP-1'));
    final preview = tileOf('eDP-1').mirrorPreviewRect;
    expect(preview, isNotNull);
    expect(tileOf('DP-1').isMirrorDropTarget, isTrue);
    await tester.pump(const Duration(milliseconds: 250));
    final laptopRect = tester.getRect(find.byWidgetPredicate(
        (w) => w is MonitorTile && w.data.id == 'eDP-1'));
    expect(laptopRect.size, tvRect.size,
        reason: 'the preview has the target\'s shape and size');
    expect((laptopRect.left - tvRect.left).abs(), lessThan(1.0));
    expect(find.text('⇄ Drop to mirror'), findsOneWidget);

    // Away again: the preview lets go.
    await gesture.moveTo(laptopCenter);
    await tester.pump();
    expect(tileOf('eDP-1').mirrorPreviewRect, isNull);
    expect(tileOf('DP-1').isMirrorDropTarget, isFalse);

    // Back over the television and release: the question is which screen
    // shows which, with the laptop proposed as the source.
    await gesture.moveTo(tvCenter);
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    expect(find.text('Show the same picture on both?'), findsOneWidget);
    expect(find.text('DP-1 shows eDP-1'), findsOneWidget);
    expect(find.text('eDP-1 shows DP-1'), findsOneWidget);
    expect(stackOrder(), ['eDP-1', 'DP-1'],
        reason: 'the drop ends the drag; normal order is back');

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    // Let the debounced save and the toast's own timers run out before the
    // tree goes away; a timer still pending fails the test for no reason of
    // its own.
    await tester.pump(const Duration(seconds: 12));
  });
}
