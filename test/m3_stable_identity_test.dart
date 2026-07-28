import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kanshi_gui/domain/output_identity.dart';
import 'package:kanshi_gui/models/monitor_tile_data.dart';
import 'package:kanshi_gui/models/profiles.dart';
import 'package:kanshi_gui/services/config_service.dart';
import 'package:kanshi_gui/services/kanshi_config_parser.dart';
import 'package:kanshi_gui/services/kanshi_config_writer.dart';
import 'package:kanshi_gui/state/kanshi_controller.dart';

import 'fakes/fake_mirror_runner.dart';
import 'fakes/fake_monitor_service.dart';

/// M3 — stable output identity.
///
/// kanshi(5) warns that connector names "may change across reboots ... or
/// creation order (typically for USB-C docks)". kanshi_gui addressed outputs
/// by connector for its whole life and kept the stable EDID description in a
/// comment only it could read, which is why a reboot or a redock could leave
/// both the arrangement and the sway workspaces pinned to it wrong.
MonitorTileData _mon({
  required String id,
  String? descriptor,
  String? manufacturer,
  double x = 0,
  double y = 0,
  double w = 1920,
  double h = 1080,
  bool enabled = true,
  int rotation = 0,
}) {
  return MonitorTileData(
    id: id,
    manufacturer: manufacturer ?? id,
    edidDescriptor: descriptor ?? '',
    x: x,
    y: y,
    width: w,
    height: h,
    rotation: rotation,
    refresh: 60,
    resolution: '${w.toInt()}x${h.toInt()}',
    orientation: w >= h ? 'landscape' : 'portrait',
    enabled: enabled,
  );
}

const _samsung = 'Samsung Electric Company S34J55x H4LR500240';
const _philips = 'Philips Consumer Electronics Company PHL 223V5 ZVC1437002369';

void main() {
  group('composeKanshiDescriptor', () {
    test('keeps the literal "Unknown" kanshi requires for missing fields', () {
      // sway reports the maintainer's laptop panel with no serial. The label
      // shown in the UI drops that, but the criteria must not: kanshi(5) says
      // a missing field "needs to be populated with the string Unknown".
      expect(
        composeKanshiDescriptor(
            make: 'InfoVision Optoelectronics (Kunshan) Co.,Ltd China',
            model: '0x057D',
            serial: ''),
        'InfoVision Optoelectronics (Kunshan) Co.,Ltd China 0x057D Unknown',
      );
    });

    test('returns null when the display supplies no identity at all', () {
      expect(composeKanshiDescriptor(), isNull);
      expect(
          composeKanshiDescriptor(
              make: 'Unknown', model: 'Unknown', serial: 'Unknown'),
          isNull);
    });
  });

  group('chooseOutputCriteria', () {
    test('prefers the description wherever it is unique', () {
      final c = chooseOutputCriteria(
        ['DP-1', 'HDMI-A-2'],
        (id) => id == 'DP-1' ? _samsung : _philips,
      );
      expect(c['DP-1']!.isDescription, isTrue);
      expect(c['HDMI-A-2']!.isDescription, isTrue);
    });

    test('falls back to connectors only for the colliding pair', () {
      // Two identical panels with no serial: kanshi genuinely cannot tell
      // them apart, so those two — and only those two — keep port names.
      final c = chooseOutputCriteria(
        ['DP-1', 'DP-2', 'HDMI-A-2'],
        (id) => id == 'HDMI-A-2' ? _philips : 'Acme Twin Unknown',
      );
      expect(c['DP-1']!.isDescription, isFalse);
      expect(c['DP-2']!.isDescription, isFalse);
      expect(c['HDMI-A-2']!.isDescription, isTrue,
          reason: 'a collision must not degrade the rest of the profile');
    });
  });

  group('the config addresses outputs by their stable identity', () {
    test('an observed descriptor is written as double-quoted criteria', () {
      final rendered = KanshiConfigWriter.render([
        Profile(name: 'Desk', monitors: [
          _mon(id: 'DP-1', descriptor: _samsung, manufacturer: _samsung),
        ]),
      ]);
      expect(rendered, contains('output "$_samsung" enable'));
      expect(rendered, contains("# kanshi_gui:port '$_samsung'='DP-1'"));
      expect(rendered, isNot(contains("output 'DP-1'")));
    });

    test('an output we have never observed keeps its connector name', () {
      // The descriptor is never guessed. A profile for hardware that has not
      // been connected since the upgrade stays on connector criteria until
      // the user is at that desk and the backend reports its EDID.
      final rendered = KanshiConfigWriter.render([
        Profile(name: 'Desk', monitors: [_mon(id: 'DP-9')]),
      ]);
      expect(rendered, contains("output 'DP-9' enable"));
    });

    test('round-trips, resolving the connector through the port annotation',
        () {
      final rendered = KanshiConfigWriter.render([
        Profile(name: 'Desk', monitors: [
          _mon(id: 'DP-1', descriptor: _samsung, manufacturer: _samsung),
          _mon(
              id: 'HDMI-A-2',
              descriptor: _philips,
              manufacturer: _philips,
              x: 3440),
        ]),
      ]);
      final back = KanshiConfigParser.parse(rendered).single.monitors;
      expect(back.map((m) => m.edidDescriptor), containsAll([_samsung, _philips]));
      expect(back.map((m) => m.id), containsAll(['DP-1', 'HDMI-A-2']),
          reason: 'the port annotation resolves the connector back');
    });

    test('a disabled output is addressed the same way', () {
      final rendered = KanshiConfigWriter.render([
        Profile(name: 'Desk', monitors: [
          _mon(id: 'DP-1', descriptor: _samsung, manufacturer: _samsung),
          _mon(
              id: 'HDMI-A-2',
              descriptor: _philips,
              manufacturer: _philips,
              enabled: false),
        ]),
      ]);
      expect(rendered, contains('output "$_philips" disable'));
    });
  });

  group('the sway workspace chain uses the same identity', () {
    test('a description is single-quoted so the exec string stays intact', () {
      final rendered = KanshiConfigWriter.render(
        [
          Profile(name: 'Desk', monitors: [
            _mon(id: 'DP-1', descriptor: _samsung, manufacturer: _samsung),
            _mon(
                id: 'HDMI-A-2',
                descriptor: _philips,
                manufacturer: _philips,
                x: 3440),
          ]),
        ],
        options: KanshiWriteOptions.swayDefaults,
      );
      expect(rendered, contains("workspace 1 output '$_samsung'"));
      expect(rendered, contains("move workspace to output '$_philips'"));
      // A literal double quote here would terminate the `exec swaymsg "…"`
      // string early and hand kanshi a mangled command.
      expect(rendered, isNot(contains('output \'"')),
          reason: 'no nested double quotes inside the exec string');
      // The whole chain must still be one balanced double-quoted argument.
      final execLine = rendered
          .split('\n')
          .firstWhere((l) => l.trim().startsWith('exec swaymsg'));
      expect('"'.allMatches(execLine).length, 2,
          reason: 'the exec argument must open and close exactly once');
    });

    test('a connector-addressed output keeps the single-quoted form', () {
      final rendered = KanshiConfigWriter.render(
        [
          Profile(name: 'Desk', monitors: [
            _mon(id: 'DP-1'),
            _mon(id: 'DP-2', x: 1920),
          ]),
        ],
        options: KanshiWriteOptions.swayDefaults,
      );
      expect(rendered, contains("workspace 1 output 'DP-1'"));
    });
  });

  group('a reboot that renumbers the connectors', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('kanshi_m3_'));
    tearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    test('the profile still matches its display on a different port',
        () async {
      // Saved at the desk with the ultrawide on DP-1. After a reboot the dock
      // enumerates it as DP-3. Before M3 the profile keyed on 'DP-1' and the
      // saved arrangement no longer applied to it.
      final cfg = ConfigService(
        configPath: '${tmp.path}/config',
        backupPrefix: '${tmp.path}/backups/config.bak',
        writeOptions: KanshiWriteOptions.neutral,
      );
      await cfg.saveProfiles([
        Profile(name: 'Desk', monitors: [
          _mon(
              id: 'DP-1',
              descriptor: _samsung,
              manufacturer: _samsung,
              x: 100),
        ]),
      ]);
      expect(File('${tmp.path}/config').readAsStringSync(),
          contains('output "$_samsung"'));

      // Same physical monitor, new connector.
      final live = _mon(
          id: 'DP-3', descriptor: _samsung, manufacturer: _samsung, x: 100);
      final c = KanshiController(
        monitors: FakeMonitorService(outputs: [live]),
        config: cfg,
        mirrorRunner: FakeMirrorRunner(),
      );
      await c.init();

      final desk = c.profiles.firstWhere((p) => p.name == 'Desk');
      expect(desk.monitors.single.id, 'DP-3',
          reason: 'rehydration matched on EDID and picked up the new port');
      expect(desk.monitors.single.edidDescriptor, _samsung,
          reason: 'the stable identity survives');
      expect(c.activeProfile?.name, 'Desk',
          reason: 'the saved arrangement is recognised as the current one');
      c.dispose();
    });
  });

  group('the hotplug settle barrier', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('kanshi_m3b_'));
    tearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    test('a dock salvo settles on the complete output set', () async {
      // Docking enumerates outputs one at a time. Every event used to run the
      // whole pipeline against a half-connected set.
      final cfg = ConfigService(
        configPath: '${tmp.path}/config',
        backupPrefix: '${tmp.path}/backups/config.bak',
        writeOptions: KanshiWriteOptions.neutral,
      );
      final a = _mon(id: 'eDP-1');
      final b = _mon(id: 'DP-1', x: 1920);
      final d = _mon(id: 'HDMI-A-2', x: 3840);
      await cfg.saveProfiles([
        Profile(name: 'Solo', monitors: [a]),
        Profile(name: 'Desk', monitors: [a, b, d]),
      ]);
      final fake = FakeMonitorService(outputs: [a]);
      final c = KanshiController(
        monitors: fake,
        config: cfg,
        mirrorRunner: FakeMirrorRunner(),
      );
      c.hotplugSettleWindow = const Duration(milliseconds: 120);
      await c.init();
      c.autoSwitchProfileEnabled = () => true;

      // The salvo.
      fake.emitOutputs([a, b]);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      fake.emitOutputs([a, b, d]);

      await Future<void>.delayed(const Duration(milliseconds: 260));

      expect(c.currentMonitors.map((m) => m.id),
          containsAll(['eDP-1', 'DP-1', 'HDMI-A-2']));
      expect(c.activeProfile?.name, 'Desk',
          reason: 'the settled set must decide which profile is active');
      c.dispose();
    });
  });
}
