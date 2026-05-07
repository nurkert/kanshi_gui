// Pins down the auto-switch-on-hotplug behaviour. The design contract:
//
//  - When `autoSwitchProfileEnabled` returns true and the connected
//    output set exactly matches a non-active profile (claim-based, see
//    `_findProfileMatchingCurrent`), the controller switches and fires
//    `onAutoSwitchedProfile`. The suggestion-toast path stays silent.
//  - When the toggle returns false, the listener falls back to the
//    legacy `onProfileSuggestion` path (a SnackBar with a Switch button).
//  - The 30-second cooldown after a *manual* profile switch suppresses
//    auto-switch — the user just chose this profile on purpose, don't
//    yank them away.
//  - An auto-switch must NOT bump the manual-switch timestamp itself,
//    or it would silence its own follow-up suggestions on the next
//    hotplug.
//  - The claim-based matcher must reject double-claims: a profile with
//    one Samsung output cannot match a connected setup with two
//    Samsungs (size mismatch).

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kanshi_gui/models/monitor_tile_data.dart';
import 'package:kanshi_gui/models/profiles.dart';
import 'package:kanshi_gui/services/config_service.dart';
import 'package:kanshi_gui/services/kanshi_config_writer.dart';
import 'package:kanshi_gui/state/kanshi_controller.dart';

import 'fakes/fake_monitor_service.dart';

MonitorTileData _mon({
  required String id,
  String? manufacturer,
  double x = 0,
  double y = 0,
  bool enabled = true,
}) =>
    MonitorTileData(
      id: id,
      manufacturer: manufacturer ?? id,
      x: x,
      y: y,
      width: 1920,
      height: 1080,
      scale: 1.0,
      rotation: 0,
      refresh: 60,
      resolution: '1920x1080',
      orientation: 'landscape',
      enabled: enabled,
    );

ConfigService _tmpConfig(Directory d) => ConfigService(
      configPath: '${d.path}/c',
      backupPrefix: '${d.path}/c.bak',
      writeOptions: KanshiWriteOptions.neutral,
    );

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('kanshi_gui_autoswitch_');
  });
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Future<KanshiController> buildController({
    required List<MonitorTileData> connected,
    required List<Profile> profiles,
  }) async {
    final cfg = _tmpConfig(tmp);
    await cfg.saveProfiles(profiles);
    final fake = FakeMonitorService(outputs: connected);
    final c = KanshiController(monitors: fake, config: cfg);
    await c.init();
    return c;
  }

  group('auto-switch on hotplug', () {
    test('fires onAutoSwitchedProfile when toggle is on and a match shows up',
        () async {
      final c = await buildController(
        connected: [_mon(id: 'A')],
        profiles: [
          Profile(name: 'solo', monitors: [_mon(id: 'A')]),
          Profile(
            name: 'desk',
            monitors: [_mon(id: 'A'), _mon(id: 'B', x: 1920)],
          ),
        ],
      );
      // Active starts as 'solo' (single-output match). Plug in B.
      c.autoSwitchProfileEnabled = () => true;
      String? switched;
      ProfileSuggestion? suggested;
      c.onAutoSwitchedProfile = (n) => switched = n;
      c.onProfileSuggestion = (s) => suggested = s;
      final fake = c.monitors as FakeMonitorService;
      fake.emitOutputs([_mon(id: 'A'), _mon(id: 'B', x: 1920)]);
      await pumpEventQueue();
      expect(switched, equals('desk'),
          reason: 'Auto-switch must fire its own callback.');
      expect(c.activeProfile?.name, equals('desk'),
          reason: 'Active profile must actually change.');
      expect(suggested, isNull,
          reason: 'Suggestion path is suppressed when auto-switch fired.');
    });

    test('falls back to onProfileSuggestion when toggle is off', () async {
      final c = await buildController(
        connected: [_mon(id: 'A')],
        profiles: [
          Profile(name: 'solo', monitors: [_mon(id: 'A')]),
          Profile(
            name: 'desk',
            monitors: [_mon(id: 'A'), _mon(id: 'B', x: 1920)],
          ),
        ],
      );
      c.autoSwitchProfileEnabled = () => false;
      String? switched;
      ProfileSuggestion? suggested;
      c.onAutoSwitchedProfile = (n) => switched = n;
      c.onProfileSuggestion = (s) => suggested = s;
      final fake = c.monitors as FakeMonitorService;
      fake.emitOutputs([_mon(id: 'A'), _mon(id: 'B', x: 1920)]);
      await pumpEventQueue();
      expect(switched, isNull,
          reason: 'Toggle off → no auto-switch.');
      expect(c.activeProfile?.name, equals('solo'),
          reason: 'Active profile must not change without consent.');
      expect(suggested, isNotNull,
          reason: 'Suggestion path stays available as a fallback.');
      expect(suggested!.profileName, equals('desk'));
    });

    test('does NOT auto-switch within the 30s manual-switch cooldown',
        () async {
      final c = await buildController(
        connected: [_mon(id: 'A')],
        profiles: [
          Profile(name: 'solo', monitors: [_mon(id: 'A')]),
          Profile(
            name: 'desk',
            monitors: [_mon(id: 'A'), _mon(id: 'B', x: 1920)],
          ),
        ],
      );
      c.autoSwitchProfileEnabled = () => true;
      // Arm the cooldown by simulating a manual switch.
      c.setActiveProfile(0);
      String? switched;
      c.onAutoSwitchedProfile = (n) => switched = n;
      final fake = c.monitors as FakeMonitorService;
      fake.emitOutputs([_mon(id: 'A'), _mon(id: 'B', x: 1920)]);
      await pumpEventQueue();
      expect(switched, isNull,
          reason: 'Within cooldown the user just chose the active profile '
              'on purpose — auto-switch must respect that.');
    });

    test('auto-switch does NOT arm the cooldown itself', () async {
      // If the auto-switch path stamped _lastManualProfileSwitchAt, then
      // a follow-up hotplug suggestion (e.g. user unplugs the second
      // monitor 5s later) would be suppressed. The auto path must leave
      // the manual timer untouched.
      final c = await buildController(
        connected: [_mon(id: 'A')],
        profiles: [
          Profile(name: 'solo', monitors: [_mon(id: 'A')]),
          Profile(
            name: 'desk',
            monitors: [_mon(id: 'A'), _mon(id: 'B', x: 1920)],
          ),
        ],
      );
      c.autoSwitchProfileEnabled = () => true;
      final fake = c.monitors as FakeMonitorService;
      // First hotplug: auto-switch into 'desk'.
      fake.emitOutputs([_mon(id: 'A'), _mon(id: 'B', x: 1920)]);
      await pumpEventQueue();
      expect(c.activeProfile?.name, equals('desk'));
      // Second hotplug: B unplugged. Connected set now matches 'solo'
      // again. Without the manual-cooldown carrying over, the listener
      // must auto-switch back.
      String? switchedAgain;
      c.onAutoSwitchedProfile = (n) => switchedAgain = n;
      fake.emitOutputs([_mon(id: 'A')]);
      await pumpEventQueue();
      expect(switchedAgain, equals('solo'),
          reason: 'Auto path must not arm the manual-switch cooldown.');
    });

    test('undoing an auto-switch arms the cooldown so a re-fire is blocked',
        () async {
      // Without this guard, a flaky cable that re-emits the same
      // outputs after the user undoes would yank them right back into
      // the auto-target profile. The undo itself counts as a "manual
      // intent to stay where I just landed", arming the 30s cooldown.
      final c = await buildController(
        connected: [_mon(id: 'A')],
        profiles: [
          Profile(name: 'solo', monitors: [_mon(id: 'A')]),
          Profile(
            name: 'desk',
            monitors: [_mon(id: 'A'), _mon(id: 'B', x: 1920)],
          ),
        ],
      );
      c.autoSwitchProfileEnabled = () => true;
      String? switched;
      c.onAutoSwitchedProfile = (n) => switched = n;
      final fake = c.monitors as FakeMonitorService;
      // First hotplug: auto-switch into 'desk'.
      fake.emitOutputs([_mon(id: 'A'), _mon(id: 'B', x: 1920)]);
      await pumpEventQueue();
      expect(switched, equals('desk'));
      // User undoes — should restore 'solo' as active.
      switched = null;
      await c.undo();
      expect(c.activeProfile?.name, equals('solo'));
      // A second hotplug with the same connected set must NOT
      // re-trigger auto-switch within the cooldown.
      fake.emitOutputs([_mon(id: 'A'), _mon(id: 'B', x: 1920)]);
      await pumpEventQueue();
      expect(switched, isNull,
          reason: 'Undo should arm the cooldown so the auto-switcher '
              'respects the user\'s explicit "stay here" intent.');
      expect(c.activeProfile?.name, equals('solo'));
    });

    test('a second hotplug with no match leaves the active profile alone',
        () async {
      final c = await buildController(
        connected: [_mon(id: 'A')],
        profiles: [
          Profile(name: 'solo', monitors: [_mon(id: 'A')]),
        ],
      );
      c.autoSwitchProfileEnabled = () => true;
      String? switched;
      c.onAutoSwitchedProfile = (n) => switched = n;
      final fake = c.monitors as FakeMonitorService;
      // Plug in an unknown monitor — no profile covers this set.
      fake.emitOutputs([_mon(id: 'A'), _mon(id: 'UNKNOWN', x: 1920)]);
      await pumpEventQueue();
      expect(switched, isNull);
      expect(c.activeProfile?.name, equals('solo'),
          reason: 'No exact match → active profile must not change.');
    });
  });

  group('claim-based profile matching', () {
    test('two identical-EDID monitors do NOT match a single-Samsung profile',
        () async {
      // Real-world: user has TWO physically identical Samsungs on the
      // desk, both reporting `manufacturer = "Samsung Display"`. A
      // profile that lists only ONE Samsung must NOT match the dual
      // setup, because the profile's single slot can't account for the
      // second connected output. Without claim tracking the old
      // any-match would (incorrectly) consider this a match.
      final c = await buildController(
        connected: [
          _mon(id: 'DP-1', manufacturer: 'Samsung Display'),
          _mon(id: 'DP-2', manufacturer: 'Samsung Display', x: 1920),
        ],
        profiles: [
          Profile(name: 'one-samsung', monitors: [
            _mon(id: 'DP-1', manufacturer: 'Samsung Display'),
          ]),
        ],
      );
      // ensureCurrentSetupMatches creates 'Current Setup' because the
      // single-Samsung profile cannot cover both connected outputs.
      expect(c.activeProfile?.name, equals('Current Setup'),
          reason: 'A single-slot profile must not double-claim two '
              'identical-EDID outputs.');
    });

    test('two identical-EDID monitors DO match a two-Samsung profile',
        () async {
      // The claim tracker assigns each connected output to a distinct
      // profile slot; with two slots and two outputs the match holds.
      final c = await buildController(
        connected: [
          _mon(id: 'DP-1', manufacturer: 'Samsung Display'),
          _mon(id: 'DP-2', manufacturer: 'Samsung Display', x: 1920),
        ],
        profiles: [
          Profile(name: 'twin-samsung', monitors: [
            _mon(id: 'DP-1', manufacturer: 'Samsung Display'),
            _mon(id: 'DP-2', manufacturer: 'Samsung Display', x: 1920),
          ]),
        ],
      );
      expect(c.activeProfile?.name, equals('twin-samsung'));
    });

    test(
        'manufacturer fallback resolves a profile saved on different ports',
        () async {
      // Profile was captured with the beamer on HDMI-A-1; user plugs
      // it into HDMI-A-2 the next day. Port id changes but EDID make
      // string matches → match still holds via pass-2 manufacturer
      // fallback.
      final c = await buildController(
        connected: [
          _mon(id: 'eDP-1', manufacturer: 'LVDS Internal'),
          _mon(id: 'HDMI-A-2', manufacturer: 'BenQ Projector', x: 1920),
        ],
        profiles: [
          Profile(name: 'beamer', monitors: [
            _mon(id: 'eDP-1', manufacturer: 'LVDS Internal'),
            _mon(id: 'HDMI-A-1', manufacturer: 'BenQ Projector', x: 1920),
          ]),
        ],
      );
      expect(c.activeProfile?.name, equals('beamer'),
          reason: 'EDID match must survive a different port assignment.');
    });
  });
}
