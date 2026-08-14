import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kanshi_gui/models/monitor_tile_data.dart';
import 'package:kanshi_gui/models/profiles.dart';
import 'package:kanshi_gui/pages/home_page.dart';
import 'package:kanshi_gui/services/app_settings.dart';
import 'package:kanshi_gui/services/config_service.dart';
import 'package:kanshi_gui/services/kanshi_config_writer.dart';
import 'package:kanshi_gui/services/workspace_daemon.dart';
import 'package:kanshi_gui/state/kanshi_controller.dart';
import 'package:kanshi_gui/widgets/workspace_sheet.dart';

import 'fakes/fake_mirror_runner.dart';
import 'fakes/fake_monitor_service.dart';
import 'fakes/fake_process_runner.dart';

/// The workspace grid has to be reachable, and it has to be the truth.
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

/// The screen tile carrying [connector].
///
/// `.first` because the tile prints the display name above the connector, and
/// these fixtures name both the same — the finder then reports the one tile
/// twice.
Finder screenOf(String connector) {
  final f = find.ancestor(
    of: find.text(connector),
    matching: find.byType(DragTarget<int>),
  );
  expect(f.evaluate(), isNotEmpty, reason: 'no screen labelled $connector');
  return f.first;
}

/// One number key on that screen.
Finder chipOn(String connector, int number) =>
    find.descendant(of: screenOf(connector), matching: find.text('$number'));

/// The numbers currently drawn on the screen labelled [connector].
///
/// Reads the rendered tree rather than the model on purpose: the model has
/// its own tests, and what this file is for is the gap between the two.
List<int> numbersOn(WidgetTester tester, String connector) => [
      for (var n = 1; n <= 9; n++)
        if (chipOn(connector, n).evaluate().isNotEmpty) n,
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
    KanshiWriteOptions? writeOptions,
  }) async {
    final mons = outputs ?? desk();
    final opts = writeOptions ?? KanshiWriteOptions.swayDefaults;
    late KanshiController c;
    late AppSettings settings;
    await tester.runAsync(() async {
      final cfg = ConfigService(
        configPath: '${tmp.path}/config',
        backupPrefix: '${tmp.path}/backups/config.bak',
        writeOptions: opts,
      );
      await cfg.saveProfiles([Profile(name: 'Office', monitors: mons)]);
      settings = AppSettings(filePath: '${tmp.path}/settings.json')
        ..workspaceManagement = mode;
      c = KanshiController(
        monitors: FakeMonitorService(outputs: mons, writeOptions: opts),
        config: cfg,
        mirrorRunner: FakeMirrorRunner(),
      )..applyStartupSettings(settings);
      await c.init();
    });
    return (c, settings);
  }

  Future<void> home(
      WidgetTester tester, KanshiController c, AppSettings s) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: HomePage(
        controller: c,
        settings: s,
        // Hermetic: the default one asks the real systemctl about a real unit
        // file, so these tests would pass or fail depending on whether the
        // machine running them happens to have the .deb installed — and the
        // subprocess's timeout timer would still be pending at test end.
        workspaceDaemon: WorkspaceDaemon(
          runner: FakeProcessRunner(),
          searchPaths: const [],
        ),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(seconds: 6));
  }

  Future<void> openGrid(
      WidgetTester tester, KanshiController c, AppSettings s) async {
    await home(tester, c, s);
    await tester.tap(find.byTooltip(r'Where the $mod+number keys go'));
    await tester.pumpAndSettle();
  }

  group('reaching it', () {
    testWidgets('the grid is one tap from the main window', (tester) async {
      // It used to be four: open Advanced, find a row, open a dropdown, read a
      // sentence. On a three-screen desk this is the second thing people want
      // after the screens are in the right order.
      final (c, s) = await boot(tester, mode: WorkspaceManagementMode.interleaved);
      addTearDown(c.dispose);
      await openGrid(tester, c, s);

      final title = find.text('Workspaces');
      expect(title, findsOneWidget);
      final box = tester.renderObject<RenderBox>(title);
      expect(box.size.height, greaterThan(8));
      expect(box.size.width, greaterThan(20));
    });

    testWidgets('a backend that cannot do it does not offer it',
        (tester) async {
      // wlr-randr, niri and the noop backend emit a neutral config with no
      // workspace exec at all. Offering the choice there would be a lie.
      final (c, s) = await boot(tester,
          mode: WorkspaceManagementMode.interleaved,
          writeOptions: KanshiWriteOptions.neutral);
      addTearDown(c.dispose);
      await home(tester, c, s);

      expect(find.byTooltip(r'Where the $mod+number keys go'), findsNothing);
    });

    testWidgets('Advanced keeps a summary and a way through', (tester) async {
      final (c, s) = await boot(tester, mode: WorkspaceManagementMode.interleaved);
      addTearDown(c.dispose);
      await home(tester, c, s);
      await tester.tap(find.byTooltip('Advanced').first);
      await tester.pumpAndSettle();

      final preview = find.textContaining('Left to right:');
      expect(preview, findsOneWidget);
      expect(tester.widget<Text>(preview).data,
          'Left to right: 1 4 7  ·  2 5 8  ·  3 6 9');
      expect(tester.renderObject<RenderBox>(preview).size.height,
          greaterThan(8));
      expect(find.text('Arrange'), findsOneWidget);
    });
  });

  group('the grid says where the numbers are', () {
    testWidgets('three screens, walking left to right', (tester) async {
      final (c, s) = await boot(tester, mode: WorkspaceManagementMode.interleaved);
      addTearDown(c.dispose);
      await openGrid(tester, c, s);

      expect(numbersOn(tester, 'DP-4'), [1, 4, 7]);
      expect(numbersOn(tester, 'DP-5'), [2, 5, 8]);
      expect(numbersOn(tester, 'eDP-1'), [3, 6, 9]);
    });

    testWidgets('a number is drawn at a size a finger could hit',
        (tester) async {
      // The whole control is these chips. One that renders at zero height is
      // the 2.0.0 failure with extra steps.
      final (c, s) = await boot(tester, mode: WorkspaceManagementMode.interleaved);
      addTearDown(c.dispose);
      await openGrid(tester, c, s);

      final box = tester.renderObject<RenderBox>(chipOn('eDP-1', 9));
      expect(box.size.height, greaterThan(8));
      expect(box.size.width, greaterThan(6));
    });

    testWidgets('two screens get a two-screen answer', (tester) async {
      final (c, s) = await boot(tester,
          mode: WorkspaceManagementMode.interleaved,
          outputs: [_mon('DP-4', 0), _mon('DP-5', 2560)]);
      addTearDown(c.dispose);
      await openGrid(tester, c, s);

      expect(numbersOn(tester, 'DP-4'), [1, 3, 5, 7, 9]);
      expect(numbersOn(tester, 'DP-5'), [2, 4, 6, 8]);
    });

    testWidgets('switched off, it says so instead of showing a plan',
        (tester) async {
      final (c, s) = await boot(tester, mode: WorkspaceManagementMode.off);
      addTearDown(c.dispose);
      await openGrid(tester, c, s);

      expect(find.textContaining('sway decides'), findsOneWidget);
      expect(find.textContaining('whichever screen you were last on'),
          findsOneWidget);
    });
  });

  group('changing it', () {
    testWidgets('a pattern reaches the controller, the file and the grid',
        (tester) async {
      final (c, s) = await boot(tester, mode: WorkspaceManagementMode.interleaved);
      addTearDown(c.dispose);
      await openGrid(tester, c, s);

      await tester.tap(find.text('A block per screen'));
      await tester.pumpAndSettle();

      expect(c.workspaceMode, WorkspaceManagementMode.grouped);
      expect(s.workspaceManagement, WorkspaceManagementMode.grouped);
      expect(c.config.writeOptions.workspaceDistribution,
          WorkspaceDistribution.grouped);
      expect(numbersOn(tester, 'DP-4'), [1, 2, 3]);
      expect(numbersOn(tester, 'eDP-1'), [7, 8, 9]);
    });

    testWidgets('tapping a number sends it one screen right, and only it',
        (tester) async {
      final (c, s) = await boot(tester, mode: WorkspaceManagementMode.interleaved);
      addTearDown(c.dispose);
      await openGrid(tester, c, s);

      await tester.tap(chipOn('DP-4', 7));
      await tester.pumpAndSettle();

      expect(numbersOn(tester, 'DP-4'), [1, 4],
          reason: 'the number that was tapped is the number that moved');
      expect(numbersOn(tester, 'DP-5'), [2, 5, 7, 8]);
      expect(numbersOn(tester, 'eDP-1'), [3, 6, 9]);
      // Moving one number out of a pattern means the pattern no longer
      // describes the desk, so the app stops claiming it does.
      expect(c.workspaceMode, WorkspaceManagementMode.custom);
      expect(s.workspaceManagement, WorkspaceManagementMode.custom);
    });

    testWidgets('the sway caveat appears only once something changed',
        (tester) async {
      // sway appends workspace→output bindings and uses the first that
      // resolves, so a workspace that already has a home keeps it until the
      // next login. Claiming the new grid is fully live would be a lie — and
      // saying so before anything changed is noise.
      final (c, s) = await boot(tester, mode: WorkspaceManagementMode.interleaved);
      addTearDown(c.dispose);
      await openGrid(tester, c, s);
      expect(find.textContaining('after your next login'), findsNothing);

      await tester.tap(find.text('A block per screen'));
      await tester.pumpAndSettle();
      expect(find.textContaining('after your next login'), findsOneWidget);
    });
  });

  group('the helper service', () {
    Future<void> pumpSheet(
      WidgetTester tester,
      KanshiController c,
      AppSettings s,
      WorkspaceDaemon daemon,
    ) async {
      // Tall enough that the whole sheet is on screen: a tap on a control
      // below the fold lands on whatever happens to be at those coordinates.
      tester.view.physicalSize = const Size(1400, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: WorkspaceSheet(controller: c, settings: s, daemon: daemon),
        ),
      ));
      await tester.pumpAndSettle();
    }

    testWidgets('no unit installed, no switch', (tester) async {
      // Running from source, or installed by something that is not the .deb.
      // A switch that cannot do anything is worse than no switch.
      final (c, s) = await boot(tester, mode: WorkspaceManagementMode.interleaved);
      addTearDown(c.dispose);
      await pumpSheet(
        tester,
        c,
        s,
        WorkspaceDaemon(
          runner: FakeProcessRunner(installed: {'systemctl'}),
          searchPaths: ['${tmp.path}/nowhere.service'],
        ),
      );

      expect(find.text('Keep this up with the app closed'), findsNothing);
    });

    testWidgets('installed and off: the switch turns it on for this user',
        (tester) async {
      final unit = File('${tmp.path}/kanshi-gui-workspaces.service')
        ..writeAsStringSync('[Unit]\n');
      final runner = FakeProcessRunner(
        installed: {'systemctl'},
        responses: {
          'systemctl --user is-enabled kanshi-gui-workspaces.service':
              ProcessResult(0, 1, 'disabled\n', ''),
        },
        fallback: ProcessResult(0, 0, '', ''),
      );
      final (c, s) = await boot(tester, mode: WorkspaceManagementMode.interleaved);
      addTearDown(c.dispose);
      await pumpSheet(tester, c, s,
          WorkspaceDaemon(runner: runner, searchPaths: [unit.path]));

      expect(find.text('Keep this up with the app closed'), findsOneWidget);
      // `is-enabled` exits non-zero for every not-enabled state, so the word
      // on stdout is what decides — reading the exit code would show every
      // disabled service as unavailable.
      final toggle = find.byType(Switch).last;
      expect(tester.widget<Switch>(toggle).value, isFalse);

      runner.responses['systemctl --user is-enabled '
          'kanshi-gui-workspaces.service'] = ProcessResult(0, 0, 'enabled\n', '');
      await tester.tap(toggle);
      await tester.pumpAndSettle();

      // `contains` compares elements with ==, and two Dart lists are only ==
      // when they are the same object — so the matcher has to be wrapped.
      expect(
        runner.calls,
        contains(equals([
          'systemctl',
          '--user',
          'enable',
          '--now',
          'kanshi-gui-workspaces.service',
        ])),
      );
      expect(tester.widget<Switch>(find.byType(Switch).last).value, isTrue);
    });

    testWidgets('turning placement on brings the helper with it',
        (tester) async {
      // "It just works": the feature is opt-in, but once someone has opted in,
      // the thing that makes it survive a reboot should not be a second
      // switch they have to find. It stays visible and one tap from off.
      final unit = File('${tmp.path}/kanshi-gui-workspaces.service')
        ..writeAsStringSync('[Unit]\n');
      final runner = FakeProcessRunner(
        installed: {'systemctl'},
        responses: {
          'systemctl --user is-enabled kanshi-gui-workspaces.service':
              ProcessResult(0, 1, 'disabled\n', ''),
        },
        fallback: ProcessResult(0, 0, '', ''),
      );
      final (c, s) = await boot(tester, mode: WorkspaceManagementMode.off);
      addTearDown(c.dispose);
      await pumpSheet(tester, c, s,
          WorkspaceDaemon(runner: runner, searchPaths: [unit.path]));

      runner.responses['systemctl --user is-enabled '
          'kanshi-gui-workspaces.service'] = ProcessResult(0, 0, 'enabled\n', '');
      await tester.tap(find.byType(Switch).first);
      await tester.pumpAndSettle();

      expect(c.workspaceMode.enabled, isTrue);
      expect(
        runner.calls,
        contains(equals([
          'systemctl',
          '--user',
          'enable',
          '--now',
          'kanshi-gui-workspaces.service',
        ])),
        reason: 'placement that stops at the window edge is half a feature',
      );
    });

    testWidgets('and turning it on again does not re-enable what was turned '
        'off on purpose', (tester) async {
      final unit = File('${tmp.path}/kanshi-gui-workspaces.service')
        ..writeAsStringSync('[Unit]\n');
      final runner = FakeProcessRunner(
        installed: {'systemctl'},
        responses: {
          'systemctl --user is-enabled kanshi-gui-workspaces.service':
              ProcessResult(0, 0, 'enabled\n', ''),
        },
        fallback: ProcessResult(0, 0, '', ''),
      );
      final (c, s) = await boot(tester, mode: WorkspaceManagementMode.off);
      addTearDown(c.dispose);
      await pumpSheet(tester, c, s,
          WorkspaceDaemon(runner: runner, searchPaths: [unit.path]));

      await tester.tap(find.byType(Switch).first);
      await tester.pumpAndSettle();

      // Already enabled, so nothing to do — and no second enable call.
      expect(
        runner.calls.where((c) => c.contains('enable')).length,
        0,
        reason: 'a service already running must not be poked',
      );
    });

    testWidgets('systemd refusing it is said out loud', (tester) async {
      final unit = File('${tmp.path}/kanshi-gui-workspaces.service')
        ..writeAsStringSync('[Unit]\n');
      final runner = FakeProcessRunner(
        installed: {'systemctl'},
        responses: {
          'systemctl --user is-enabled kanshi-gui-workspaces.service':
              ProcessResult(0, 1, 'disabled\n', ''),
          'systemctl --user enable --now kanshi-gui-workspaces.service':
              ProcessResult(0, 1, '', 'Failed to connect to bus.'),
        },
        fallback: ProcessResult(0, 0, '', ''),
      );
      final (c, s) = await boot(tester, mode: WorkspaceManagementMode.interleaved);
      addTearDown(c.dispose);
      await pumpSheet(tester, c, s,
          WorkspaceDaemon(runner: runner, searchPaths: [unit.path]));

      await tester.tap(find.byType(Switch).last);
      await tester.pumpAndSettle();

      expect(find.textContaining('Failed to connect to bus.'), findsOneWidget);
      expect(tester.widget<Switch>(find.byType(Switch).last).value, isFalse,
          reason: 'the switch must not show a state systemd does not agree to');
    });
  });
}
