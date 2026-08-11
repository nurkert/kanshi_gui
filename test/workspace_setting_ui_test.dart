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

import 'fakes/fake_mirror_runner.dart';
import 'fakes/fake_monitor_service.dart';

/// The workspace setting has to be reachable, and it has to say what it does.
///
/// M8 deleted ten preferences and M9 deleted the question this one asked. What
/// survived was a value in settings.json — `workspaceManagement: interleaved` —
/// with no control anywhere in the app to see it or change it, while the app
/// quietly did something else. A preference nobody can reach is not a
/// preference.
///
/// These measure rather than assert presence: a control in the tree that
/// renders at zero height is exactly the failure 2.0.0 shipped.
MonitorTileData _mon(String id, double x) => MonitorTileData(
      id: id,
      manufacturer: id,
      edidDescriptor: 'Make $id Serial$id',
      x: x,
      y: 0,
      width: 2560,
      height: 1440,
      scale: 1.0,
      rotation: 0,
      refresh: 60,
      resolution: '2560x1440',
      orientation: 'landscape',
      enabled: true,
    );

List<MonitorTileData> desk() => [
      _mon('DP-4', 8072),
      _mon('DP-5', 10632),
      _mon('eDP-1', 13192),
    ];

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('kanshi_wsui_'));
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Future<(KanshiController, AppSettings)> boot(
    WidgetTester tester, {
    required WorkspaceManagementMode mode,
    List<MonitorTileData>? outputs,
  }) async {
    final mons = outputs ?? desk();
    late KanshiController c;
    late AppSettings settings;
    await tester.runAsync(() async {
      final cfg = ConfigService(
        configPath: '${tmp.path}/config',
        backupPrefix: '${tmp.path}/backups/config.bak',
        writeOptions: KanshiWriteOptions.swayDefaults,
      );
      await cfg.saveProfiles([Profile(name: 'Office', monitors: mons)]);
      settings = AppSettings(filePath: '${tmp.path}/settings.json')
        ..workspaceManagement = mode;
      c = KanshiController(
        monitors: FakeMonitorService(
            outputs: mons, writeOptions: KanshiWriteOptions.swayDefaults),
        config: cfg,
        mirrorRunner: FakeMirrorRunner(),
      )..applyStartupSettings(settings);
      await c.init();
    });
    return (c, settings);
  }

  Future<void> openAdvanced(WidgetTester tester, KanshiController c,
      AppSettings s) async {
    await tester
        .pumpWidget(MaterialApp(home: HomePage(controller: c, settings: s)));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(seconds: 6));
    await tester.tap(find.byTooltip('Advanced').first);
    await tester.pumpAndSettle();
  }

  testWidgets('the workspace setting is on screen and readable', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final (c, settings) =
        await boot(tester, mode: WorkspaceManagementMode.interleaved);
    addTearDown(c.dispose);
    await openAdvanced(tester, c, settings);

    final label = find.text('Workspaces');
    expect(label, findsOneWidget,
        reason: 'a preference with no control is not a preference');
    final box = tester.renderObject<RenderBox>(label);
    expect(box.size.height, greaterThan(8));
    expect(box.size.width, greaterThan(20));

    // The mode in the file is the mode on screen.
    expect(find.text('Number keys walk left to right'), findsWidgets);
  });

  testWidgets('it answers where mod+9 goes, for these screens', (tester) async {
    // The mode names describe a rule. The question people actually have is
    // which screen a number key takes them to, and the answer depends on how
    // many screens are plugged in — so the sheet works it out for them.
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final (c, settings) =
        await boot(tester, mode: WorkspaceManagementMode.interleaved);
    addTearDown(c.dispose);
    await openAdvanced(tester, c, settings);

    final preview = find.textContaining('Left to right:');
    expect(preview, findsOneWidget);
    expect(
        (tester.widget<Text>(preview)).data,
        'Left to right: 1 4 7  ·  2 5 8  ·  3 6 9');
    expect(tester.renderObject<RenderBox>(preview).size.height, greaterThan(8));
  });

  testWidgets('two screens get a two-screen answer', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final (c, settings) = await boot(tester,
        mode: WorkspaceManagementMode.interleaved,
        outputs: [_mon('DP-4', 0), _mon('DP-5', 2560)]);
    addTearDown(c.dispose);
    await openAdvanced(tester, c, settings);

    expect((tester.widget<Text>(find.textContaining('Left to right:'))).data,
        'Left to right: 1 3 5 7 9  ·  2 4 6 8');
  });

  testWidgets('turning it off says so rather than showing a grid',
      (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final (c, settings) =
        await boot(tester, mode: WorkspaceManagementMode.off);
    addTearDown(c.dispose);
    await openAdvanced(tester, c, settings);

    expect(find.text('Leave them alone'), findsWidgets);
    expect(find.textContaining('left to sway'), findsOneWidget);
  });

  testWidgets('choosing a mode reaches the controller and the file',
      (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final (c, settings) =
        await boot(tester, mode: WorkspaceManagementMode.interleaved);
    addTearDown(c.dispose);
    await openAdvanced(tester, c, settings);

    await tester.tap(find.text('Number keys walk left to right').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('One block of numbers per screen').last);
    await tester.pumpAndSettle();

    expect(settings.workspaceManagement, WorkspaceManagementMode.grouped);
    expect(c.workspaceMode, WorkspaceManagementMode.grouped);
    expect(c.config.writeOptions.workspaceDistribution,
        WorkspaceDistribution.grouped);
    expect((tester.widget<Text>(find.textContaining('Left to right:'))).data,
        'Left to right: 1 2 3  ·  4 5 6  ·  7 8 9');
    // sway appends workspace→output bindings and uses the first that
    // resolves, so a workspace that already has a home keeps it until the
    // next login. Claiming the new grid is fully live would be a lie.
    expect(find.textContaining('after your next login'), findsOneWidget);
  });

  testWidgets('the sway caveat is not shown before anything changed',
      (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final (c, settings) =
        await boot(tester, mode: WorkspaceManagementMode.interleaved);
    addTearDown(c.dispose);
    await openAdvanced(tester, c, settings);

    expect(find.textContaining('after your next login'), findsNothing);
  });

  testWidgets('a backend that cannot do it does not offer it', (tester) async {
    // wlr-randr, niri and the noop backend emit a neutral config with no
    // workspace exec at all. Offering the choice there would be a lie.
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    late KanshiController c;
    late AppSettings settings;
    await tester.runAsync(() async {
      final cfg = ConfigService(
        configPath: '${tmp.path}/config',
        backupPrefix: '${tmp.path}/backups/config.bak',
        writeOptions: KanshiWriteOptions.neutral,
      );
      await cfg.saveProfiles([Profile(name: 'Office', monitors: desk())]);
      settings = AppSettings(filePath: '${tmp.path}/settings.json')
        ..workspaceManagement = WorkspaceManagementMode.interleaved;
      c = KanshiController(
        monitors: FakeMonitorService(
            outputs: desk(), writeOptions: KanshiWriteOptions.neutral),
        config: cfg,
        mirrorRunner: FakeMirrorRunner(),
      )..applyStartupSettings(settings);
      await c.init();
    });
    addTearDown(c.dispose);
    await openAdvanced(tester, c, settings);

    expect(find.text('Workspaces'), findsNothing);
  });
}
