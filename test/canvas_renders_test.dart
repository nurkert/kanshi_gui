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
import 'package:kanshi_gui/widgets/screen_strip.dart';

import 'fakes/fake_mirror_runner.dart';
import 'fakes/fake_monitor_service.dart';

/// The canvas must actually occupy the space the Scaffold leaves it.
///
/// v2.0.0 shipped with an empty canvas. Nothing threw, nothing was logged,
/// every unit test passed and the model held all three monitors — but the
/// Scaffold hands its body a LOOSE height, every child of the canvas Stack is
/// a `Positioned.fill`, and a Stack with no non-positioned child takes no
/// height from that. The row collapsed to 0 px, `computeDisplay` divided the
/// viewport height into the layout and got a scale factor of 0, and all three
/// tiles rendered as 0x0 on top of each other. The app was unusable.
///
/// The lesson is that "the widget is in the tree" is not the same claim as
/// "the user can see it", and only a test that measures the render box can
/// tell the two apart.
MonitorTileData _mon(String id, double x, double y, double w, double h) =>
    MonitorTileData(
      id: id,
      manufacturer: id,
      edidDescriptor: 'Make $id Serial$id',
      x: x,
      y: y,
      width: w,
      height: h,
      scale: 1.0,
      rotation: 0,
      refresh: 60,
      resolution: '${w.toInt()}x${h.toInt()}',
      orientation: 'landscape',
      enabled: true,
    );

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('kanshi_canvas_'));
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  /// Boots a controller over a real (temporary) config the way the app does.
  ///
  /// `init()` does file and process I/O, which never completes under the
  /// FakeAsync clock a `testWidgets` body runs in — hence `runAsync`.
  Future<(KanshiController, AppSettings)> boot(
    WidgetTester tester,
    List<MonitorTileData> mons,
  ) async {
    late KanshiController c;
    late AppSettings settings;
    await tester.runAsync(() async {
      final cfg = ConfigService(
        configPath: '${tmp.path}/config',
        backupPrefix: '${tmp.path}/backups/config.bak',
        writeOptions: KanshiWriteOptions.swayDefaults,
      );
      await cfg.saveProfiles([Profile(name: 'Desk', monitors: mons)]);
      c = KanshiController(
        monitors: FakeMonitorService(
            outputs: mons, writeOptions: KanshiWriteOptions.swayDefaults),
        config: cfg,
        mirrorRunner: FakeMirrorRunner(),
      );
      await c.init();
      settings = AppSettings(filePath: '${tmp.path}/settings.json');
    });
    return (c, settings);
  }

  Future<void> pumpHome(
      WidgetTester tester, KanshiController c, AppSettings s) async {
    await tester.pumpWidget(
        MaterialApp(home: HomePage(controller: c, settings: s)));
    await tester.pump(const Duration(milliseconds: 400));
    // `initState` kicks off a health probe that shells out with a 5 s timeout.
    // Under FakeAsync the process never returns, so the only thing that
    // settles that future is the timeout timer — and a timer still pending
    // when the tree is torn down fails the test for the wrong reason.
    await tester.pump(const Duration(seconds: 6));
  }

  // The maintainer's real desk: two 1440p panels and a laptop, parked at the
  // large virtual coordinates a multi-head sway session actually produces.
  List<MonitorTileData> desk() => [
        _mon('DP-4', 8072, 1238, 2560, 1440),
        _mon('DP-5', 10632, 1238, 2560, 1440),
        _mon('eDP-1', 13192, 1542, 1920, 1080),
      ];

  testWidgets('the canvas is given a real height', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final (c, settings) = await boot(tester, desk());
    addTearDown(c.dispose);
    await pumpHome(tester, c, settings);

    final canvas =
        tester.renderObject<RenderBox>(find.byType(LayoutBuilder).last);
    expect(canvas.size.height, greaterThan(100),
        reason: 'the canvas collapsed — every tile would scale to nothing');
    expect(canvas.size.width, greaterThan(100));
  });

  testWidgets('every monitor is drawn at a visible size', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final (c, settings) = await boot(tester, desk());
    addTearDown(c.dispose);
    await pumpHome(tester, c, settings);

    final tiles = find.byType(MonitorTile);
    expect(tiles, findsNWidgets(3));

    final boxes = tiles
        .evaluate()
        .map((e) => e.renderObject as RenderBox)
        .toList(growable: false);
    for (final box in boxes) {
      expect(box.size.width, greaterThan(20), reason: 'tile rendered too small');
      expect(box.size.height, greaterThan(20));
    }

    // Three separate screens must not land on one another: a zero scale
    // factor collapses every tile onto the same point, which still counts as
    // "three MonitorTiles are present".
    final origins = boxes.map((b) => b.localToGlobal(Offset.zero)).toSet();
    expect(origins, hasLength(3),
        reason: 'the tiles are stacked on the same point');
  });

  testWidgets('the title bar controls sit at the right edge', (tester) async {
    // A Row splits free space BY FLEX. The setup name was a loose `Flexible`
    // (flex 1) that shrink-wraps to a short name, next to a `Spacer` (also
    // flex 1) — and a loose child that under-uses its share does not hand the
    // remainder back. The trailing controls could therefore only ever reach
    // the middle of the bar, leaving hundreds of pixels dead at the right on
    // every launch. Nothing overflows and nothing is logged, so only a
    // measured position catches it.
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final (c, settings) = await boot(tester, desk());
    addTearDown(c.dispose);
    await pumpHome(tester, c, settings);

    final advanced = tester.renderObject<RenderBox>(
        find.byTooltip('Advanced').first);
    final right = advanced.localToGlobal(Offset.zero).dx + advanced.size.width;
    expect(right, greaterThan(1400 * 0.9),
        reason: 'the trailing controls are stranded mid-bar, not at the edge');
  });

  testWidgets('a single monitor still fills the canvas', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final (c, settings) = await boot(tester, [_mon('eDP-1', 0, 0, 1920, 1080)]);
    addTearDown(c.dispose);
    await pumpHome(tester, c, settings);

    final box = tester.renderObject<RenderBox>(find.byType(MonitorTile));
    expect(box.size.width, greaterThan(100));
    expect(box.size.height, greaterThan(50));
  });

  testWidgets('clicking empty canvas closes the screen settings', (tester) async {
    // Clicking a screen opens the settings strip at the foot of the window.
    // Closing it used to require finding and hitting its ✕ — but clicking
    // away from a thing is what dismisses it everywhere else, so the strip
    // has to answer to that too.
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final (c, settings) = await boot(tester, desk());
    addTearDown(c.dispose);
    await pumpHome(tester, c, settings);

    double stripHeight() =>
        tester.renderObject<RenderBox>(find.byType(ScreenStrip)).size.height;
    expect(stripHeight(), 0, reason: 'nothing selected, nothing to show');

    await tester.tap(find.byType(MonitorTile).first);
    await tester.pumpAndSettle();
    expect(stripHeight(), greaterThan(0),
        reason: 'selecting a screen must open its settings');

    // A corner of the canvas no tile occupies.
    final canvas = tester.renderObject<RenderBox>(find.byType(LayoutBuilder).last);
    final origin = canvas.localToGlobal(Offset.zero);
    await tester.tapAt(origin + const Offset(6, 6));
    await tester.pumpAndSettle();
    expect(stripHeight(), 0,
        reason: 'clicking empty canvas must close the settings again');
  });

  testWidgets('clicking another screen keeps the settings open', (tester) async {
    // The dismissal must not fire between two screens: switching selection is
    // one gesture, not close-then-open.
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final (c, settings) = await boot(tester, desk());
    addTearDown(c.dispose);
    await pumpHome(tester, c, settings);

    await tester.tap(find.byType(MonitorTile).first);
    await tester.pumpAndSettle();
    await tester.tap(find.byType(MonitorTile).at(1));
    await tester.pumpAndSettle();

    expect(tester.renderObject<RenderBox>(find.byType(ScreenStrip)).size.height,
        greaterThan(0));
  });

  testWidgets('renaming a setup is offered in words', (tester) async {
    // A capture is called "Setup 1" until the user says otherwise. Between M8
    // and 2.0.1 there was no way to say otherwise at all — `renameProfile`
    // had no caller — and an unlabelled pencil would only have moved the
    // problem. The word has to be on screen.
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final (c, settings) = await boot(tester, desk());
    addTearDown(c.dispose);
    await pumpHome(tester, c, settings);

    await tester.tap(find.text('Desk'));
    await tester.pumpAndSettle();

    expect(find.text('Rename'), findsWidgets,
        reason: 'the way to rename a setup must be readable, not guessable');
    expect(find.text('Forget'), findsWidgets);
  });
}
