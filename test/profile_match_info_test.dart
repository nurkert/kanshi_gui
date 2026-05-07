// Pins down `KanshiController.profileMatchInfo` — the per-profile
// match score the sidebar uses to colour its compatibility dot.
//
// The contract:
//   - full   → every profile slot has a distinct connected output
//              AND counts are equal (the auto-switcher's trigger
//              condition).
//   - partial→ some profile slots match, but the fit isn't 1-to-1
//              (counts differ, or some slots are unmatched).
//   - none   → zero profile slots match (or either side is empty).
//
// The matcher is claim-based (id-exact first, then manufacturer
// fallback) so identical-EDID monitors can't double-claim a single
// profile slot — important because the GUI's hotplug auto-switch
// hangs off this exact computation.

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

Future<KanshiController> _build({
  required List<MonitorTileData> connected,
  required List<Profile> profiles,
  required Directory tmp,
}) async {
  final cfg = _tmpConfig(tmp);
  await cfg.saveProfiles(profiles);
  final fake = FakeMonitorService(outputs: connected);
  final c = KanshiController(monitors: fake, config: cfg);
  await c.init();
  return c;
}

void main() {
  late Directory tmp;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('kanshi_gui_match_info_');
  });
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('full match', () {
    test('every profile slot finds a 1-to-1 partner via id-exact', () async {
      final c = await _build(
        tmp: tmp,
        connected: [_mon(id: 'A'), _mon(id: 'B', x: 1920)],
        profiles: [
          Profile(
            name: 'desk',
            monitors: [_mon(id: 'A'), _mon(id: 'B', x: 1920)],
          ),
        ],
      );
      final info = c.profileMatchInfo(0);
      expect(info.status, equals(ProfileMatchStatus.full));
      expect(info.matched, equals(2));
      expect(info.profileEnabled, equals(2));
      expect(info.currentEnabled, equals(2));
      expect(info.missing, isEmpty);
    });

    test('manufacturer fallback alone is enough for a full match',
        () async {
      // Profile was saved with the beamer on HDMI-A-1, user plugs it
      // into HDMI-A-2 — port id changed but manufacturer matches, so
      // the match is still complete after the fallback pass.
      final c = await _build(
        tmp: tmp,
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
      expect(c.profileMatchInfo(0).status, equals(ProfileMatchStatus.full));
    });
  });

  group('partial match', () {
    test('profile is a strict subset of the connected set', () async {
      // Profile expects 2 monitors; user has 3 connected (the third
      // is "extra"). The fit isn't 1-to-1 so this is partial, not
      // full.
      final c = await _build(
        tmp: tmp,
        connected: [
          _mon(id: 'A'),
          _mon(id: 'B', x: 1920),
          _mon(id: 'C', x: 3840),
        ],
        profiles: [
          Profile(
            name: 'half',
            monitors: [_mon(id: 'A'), _mon(id: 'B', x: 1920)],
          ),
        ],
      );
      final info = c.profileMatchInfo(0);
      expect(info.status, equals(ProfileMatchStatus.partial));
      expect(info.matched, equals(2));
      expect(info.profileEnabled, equals(2));
      expect(info.currentEnabled, equals(3));
      expect(info.missing, isEmpty,
          reason: 'No profile slot is unmatched; the partial-ness '
              'comes from the count mismatch on the *current* side.');
    });

    test('connected set is a strict subset of the profile (one missing)',
        () async {
      // User undocked one monitor; profile expects 3 but only 2 are
      // there. The unmatched profile slot must show up in `missing`
      // so the tooltip can say "DP-2 fehlt".
      final c = await _build(
        tmp: tmp,
        connected: [_mon(id: 'A'), _mon(id: 'B', x: 1920)],
        profiles: [
          Profile(name: 'triple', monitors: [
            _mon(id: 'A'),
            _mon(id: 'B', x: 1920),
            _mon(id: 'C', x: 3840),
          ]),
        ],
      );
      final info = c.profileMatchInfo(0);
      expect(info.status, equals(ProfileMatchStatus.partial));
      expect(info.matched, equals(2));
      expect(info.profileEnabled, equals(3));
      expect(info.currentEnabled, equals(2));
      expect(info.missing, equals(['C']));
    });

    test('one profile slot matches, the other has no claimant', () async {
      // 1-of-2 match: counts equal, but the second profile slot
      // (DP-2) doesn't appear in the connected set. Status is
      // partial because matched < profileEnabled.
      final c = await _build(
        tmp: tmp,
        connected: [_mon(id: 'A'), _mon(id: 'WAT', x: 1920)],
        profiles: [
          Profile(name: 'pair', monitors: [
            _mon(id: 'A'),
            _mon(id: 'B', x: 1920),
          ]),
        ],
      );
      final info = c.profileMatchInfo(0);
      expect(info.status, equals(ProfileMatchStatus.partial));
      expect(info.matched, equals(1));
      expect(info.missing, equals(['B']));
    });
  });

  group('none', () {
    test('zero overlap — completely unrelated profile', () async {
      final c = await _build(
        tmp: tmp,
        connected: [_mon(id: 'A')],
        profiles: [
          Profile(name: 'unrelated', monitors: [_mon(id: 'XYZ')]),
        ],
      );
      final info = c.profileMatchInfo(0);
      // Active becomes 'unrelated' (only one profile, picked as
      // default), but the match info itself is what we're testing.
      expect(info.status, equals(ProfileMatchStatus.none));
      expect(info.matched, equals(0));
      expect(info.missing, equals(['XYZ']));
    });

    test('no monitors connected at all', () async {
      final c = await _build(
        tmp: tmp,
        connected: const [],
        profiles: [
          Profile(name: 'desk', monitors: [_mon(id: 'A')]),
        ],
      );
      // With nothing plugged in, every profile is `none`.
      expect(c.profileMatchInfo(0).status, equals(ProfileMatchStatus.none));
    });

    test('profile has no enabled monitors', () async {
      final c = await _build(
        tmp: tmp,
        connected: [_mon(id: 'A')],
        profiles: [
          Profile(name: 'empty', monitors: [_mon(id: 'A', enabled: false)]),
        ],
      );
      expect(c.profileMatchInfo(0).status, equals(ProfileMatchStatus.none));
    });
  });

  group('claim-based disambiguation', () {
    test(
        'a single-Samsung profile is partial (not full) against a '
        'two-Samsung desk', () async {
      // The whole point of claim tracking: without it, both connected
      // Samsungs would pile onto the single profile slot's
      // manufacturer fallback and the profile would falsely look
      // full. With claim tracking, only one Samsung claims the slot;
      // the other contributes to the count mismatch → partial.
      final c = await _build(
        tmp: tmp,
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
      final info = c.profileMatchInfo(0);
      expect(info.status, equals(ProfileMatchStatus.partial));
      expect(info.matched, equals(1));
      expect(info.profileEnabled, equals(1));
      expect(info.currentEnabled, equals(2));
    });

    test('a two-Samsung profile is full against a two-Samsung desk',
        () async {
      // Same desk, but now the profile has two Samsung slots — claim
      // tracking gives each connected Samsung a distinct slot.
      final c = await _build(
        tmp: tmp,
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
      expect(c.profileMatchInfo(0).status, equals(ProfileMatchStatus.full));
    });
  });

  group('out-of-range index', () {
    test('returns a `none` info object instead of throwing', () async {
      final c = await _build(
        tmp: tmp,
        connected: [_mon(id: 'A')],
        profiles: [
          Profile(name: 'solo', monitors: [_mon(id: 'A')]),
        ],
      );
      final info = c.profileMatchInfo(99);
      expect(info.status, equals(ProfileMatchStatus.none));
      expect(info.matched, equals(0));
      expect(info.profileEnabled, equals(0));
      expect(info.missing, isEmpty);
    });
  });
}
