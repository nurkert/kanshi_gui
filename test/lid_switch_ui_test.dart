import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kanshi_gui/models/monitor_tile_data.dart';
import 'package:kanshi_gui/services/app_settings.dart';
import 'package:kanshi_gui/services/config_service.dart';
import 'package:kanshi_gui/services/kanshi_config_writer.dart';
import 'package:kanshi_gui/services/lid_switch.dart';
import 'package:kanshi_gui/services/sway_config_files.dart';
import 'package:kanshi_gui/state/kanshi_controller.dart';
import 'package:kanshi_gui/widgets/advanced_sheet.dart';
import 'package:kanshi_gui/widgets/lid_switch_dialog.dart';

import 'fakes/fake_mirror_runner.dart';
import 'fakes/fake_monitor_service.dart';
import 'fakes/fake_process_runner.dart';

/// The lid switch as the user sees it: where it is, and that nothing is
/// written before the lines have been shown.
MonitorTileData _mon(String id, double x) => MonitorTileData(
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
  group('the dialog', () {
    late List<String> calls;

    Future<void> open(WidgetTester tester, LidSwitchFacts facts,
        {bool on = true}) async {
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => LidSwitchDialog.show(
                context,
                on: on,
                facts: facts,
                onConfirm: () async {
                  calls.add('confirm');
                  return const OpResult.ok('done');
                },
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    setUp(() => calls = []);

    testWidgets('shows the lines and the file before anything is written',
        (tester) async {
      await open(
        tester,
        const LidSwitchFacts(
          swayConfigPath: '/home/u/.config/sway/config',
          writable: true,
          scan: LidSwitchScan(),
        ),
      );
      expect(find.textContaining('/home/u/.config/sway/config'), findsOneWidget);
      expect(find.textContaining(LidSwitchBinding.lines.first), findsOneWidget);
      expect(calls, isEmpty);
      await tester.tap(find.text('Add and switch on'));
      await tester.pumpAndSettle();
      expect(calls, ['confirm']);
      expect(find.byType(AlertDialog), findsNothing);
    });

    testWidgets("names the user's own lid binding it would override",
        (tester) async {
      await open(
        tester,
        const LidSwitchFacts(
          swayConfigPath: '/cfg',
          writable: true,
          scan: LidSwitchScan(foreign: [
            SwayConfigLine('/cfg', 12, 'bindswitch lid:on exec swaylock'),
          ]),
        ),
      );
      expect(find.textContaining('bindswitch lid:on exec swaylock'),
          findsOneWidget);
      expect(find.textContaining('line 12'), findsOneWidget);
    });

    testWidgets('a config it cannot change gets the lines, and no button',
        (tester) async {
      await open(
        tester,
        const LidSwitchFacts(
          swayConfigPath: '/etc/sway/config',
          scan: LidSwitchScan(),
        ),
      );
      expect(find.textContaining('cannot change'), findsOneWidget);
      expect(find.text('Add and switch on'), findsNothing);
      expect(find.text('Close'), findsOneWidget);
    });
  });

  testWidgets('Advanced shows the switch on a laptop', (tester) async {
    late Directory tmp;
    late KanshiController c;
    await tester.runAsync(() async {
      tmp = Directory.systemTemp.createTempSync('lid_ui_');
      final sway = File('${tmp.path}/sway/config')
        ..createSync(recursive: true)
        ..writeAsStringSync('set \$mod Mod4\n');
      final monitors = FakeMonitorService(
        writeOptions: KanshiWriteOptions.swayDefaults,
        outputs: [_mon('eDP-1', 0), _mon('DP-1', 1920)],
      );
      c = KanshiController(
        monitors: monitors,
        config: ConfigService(
          configPath: '${tmp.path}/kanshi/config',
          backupPrefix: '${tmp.path}/backups/config.bak',
          writeOptions: monitors.writeOptions,
        ),
        mirrorRunner: FakeMirrorRunner(),
        processRunner: FakeProcessRunner(
          installed: {LidSwitchBinding.helper},
          responses: {
            'swaymsg -t get_version': ProcessResult(
                0, 0, '{"loaded_config_file_name":"${sway.path}"}', ''),
          },
        ),
      );
      c.applyStartupSettings(AppSettings(filePath: '${tmp.path}/s.json'));
      await c.init();
    });
    addTearDown(() {
      c.dispose();
      tmp.deleteSync(recursive: true);
    });

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: AdvancedSheet(
          controller: c,
          settings: AppSettings(filePath: '${tmp.path}/s.json'),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Lid'), findsOneWidget);
    final tile = find.widgetWithText(
        SwitchListTile, 'Closed lid switches the screen off');
    expect(tile, findsOneWidget);
    expect(tester.widget<SwitchListTile>(tile).value, isFalse);
  });
}
