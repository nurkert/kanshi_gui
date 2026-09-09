// The mirror entries a screen's menu offers, as the user sees them.
//
// Green unit tests once shipped a release with an empty window; this pumps
// the real HomePage and opens the real menu.

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
  setUp(() => tmp = Directory.systemTemp.createTempSync('kanshi_menu_'));
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  testWidgets('a screen offers both mirror directions by name',
      (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

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

    // The laptop's tile: its menu button is the one inside it.
    final laptopTile = find.byWidgetPredicate(
        (w) => w is MonitorTile && w.data.id == 'eDP-1');
    expect(laptopTile, findsOneWidget);
    await tester.tap(find.descendant(
        of: laptopTile, matching: find.byIcon(Icons.more_vert)));
    await tester.pumpAndSettle();

    expect(find.text('Show this screen on…'), findsOneWidget);
    expect(find.text('Show another screen here…'), findsOneWidget);
    expect(find.text('Mirror onto…'), findsNothing,
        reason: 'the ambiguous wording is gone');

    await tester.tap(find.text('Show this screen on…'));
    await tester.pumpAndSettle();
    expect(find.text('DP-1 (Samsung)'), findsOneWidget,
        reason: 'the television is offered as the screen to show this on');

    // Choosing it makes the television the copy — not the laptop. The
    // controller writes the config and talks to the (fake) compositor, which
    // is real I/O, hence runAsync.
    await tester.runAsync(() async {
      await tester.tap(find.text('DP-1 (Samsung)'));
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 1500));
    });
    await tester.pump();
    final after = {for (final m in c.activeMonitors) m.id: m};
    expect(after['DP-1']!.mirrorOf, 'eDP-1');
    expect(after['eDP-1']!.mirrorOf, isNull);
    // Let the toast and the debounced save run out before teardown.
    await tester.pump(const Duration(seconds: 12));
  });
}
