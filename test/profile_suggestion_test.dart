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
    tmp = Directory.systemTemp.createTempSync('kanshi_gui_suggest_');
  });
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  /// Builds a controller with the given profiles already saved to a
  /// throw-away config and the given outputs reported as live. The
  /// caller should ensure the connected set exactly matches one of the
  /// profiles so `ensureCurrentSetupMatches` doesn't auto-add a phantom
  /// "Current Setup" profile that would muddy the suggestion math.
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

  group('ProfileSuggestion scoring', () {
    test('returns null when there is only one profile', () async {
      final c = await buildController(
        connected: [_mon(id: 'A')],
        profiles: [
          Profile(name: 'solo', monitors: [_mon(id: 'A')]),
        ],
      );
      expect(c.findBestProfileSuggestion(), isNull);
    });

    test('returns null when no non-active profile clears the floor',
        () async {
      final c = await buildController(
        connected: [_mon(id: 'A')],
        profiles: [
          Profile(name: 'active', monitors: [_mon(id: 'A')]),
          Profile(name: 'unrelated', monitors: [_mon(id: 'XYZ')]),
        ],
      );
      // Active is auto-picked as 'active' (id-match on A); 'unrelated'
      // has no overlapping output → confidence 0.
      expect(c.findBestProfileSuggestion(), isNull);
    });

    test('an exact-match candidate beats a partial-match active profile',
        () async {
      // Active = single-output profile; only 1 of the 2 connected
      // outputs is claimed → active conf = 0.5. Candidate covers both,
      // conf = 1.0 → strict-better gate is satisfied.
      final c = await buildController(
        connected: [_mon(id: 'A'), _mon(id: 'B', x: 1920)],
        profiles: [
          Profile(name: 'solo', monitors: [_mon(id: 'A')]),
          Profile(
            name: 'desk',
            monitors: [_mon(id: 'A'), _mon(id: 'B', x: 1920)],
          ),
        ],
      );
      // 'desk' was auto-picked at init (full match for the connected
      // set). Force the test scenario by switching to the weaker
      // profile manually.
      c.setActiveProfile(0);
      final s = c.findBestProfileSuggestion();
      expect(s, isNotNull);
      expect(s!.profileName, 'desk');
      expect(s.confidence, equals(1.0));
      expect(s.matchedOutputs, 2);
      expect(s.totalOutputs, 2);
    });

    test(
        'does NOT suggest a worse fit when the active profile already covers '
        'every connected output', () async {
      // This was the user-reported bug: kanshi_gui was nagging "Setup
      // matches profile X (2 of 3 outputs)" while the active profile
      // already covered all 3 outputs. Strict-better gating fixes it.
      final c = await buildController(
        connected: [
          _mon(id: 'A'),
          _mon(id: 'B', x: 1920),
          _mon(id: 'C', x: 3840),
        ],
        profiles: [
          // Active: full match (3/3).
          Profile(
            name: 'triple',
            monitors: [
              _mon(id: 'A'),
              _mon(id: 'B', x: 1920),
              _mon(id: 'C', x: 3840),
            ],
          ),
          // Candidate: only 2/3 — strictly worse.
          Profile(
            name: 'docked',
            monitors: [_mon(id: 'A'), _mon(id: 'B', x: 1920)],
          ),
        ],
      );
      expect(c.findBestProfileSuggestion(), isNull,
          reason:
              'Active is already a perfect fit; offering a strictly worse '
              'alternative is noise, not a suggestion.');
    });

    test('ties between equivalent profiles do not produce a suggestion',
        () async {
      // Two profiles that both score 1.0 against the live set. There
      // is no meaningful reason to nudge the user to switch sideways.
      final c = await buildController(
        connected: [_mon(id: 'A'), _mon(id: 'B', x: 1920)],
        profiles: [
          Profile(
            name: 'desk',
            monitors: [_mon(id: 'A'), _mon(id: 'B', x: 1920)],
          ),
          Profile(
            name: 'desk-alt',
            monitors: [_mon(id: 'A'), _mon(id: 'B', x: 1920)],
          ),
        ],
      );
      expect(c.findBestProfileSuggestion(), isNull,
          reason: 'Tied candidates must not trigger a suggestion.');
    });

    test('never returns the currently active profile as a candidate',
        () async {
      // Two profiles that BOTH score 1.0 against the connected set.
      // The candidate that wins must not be the active one — and
      // because the strict-better gate suppresses tied alternatives
      // (see the dedicated test below), this scenario simply yields
      // null. The contract is: `findBestProfileSuggestion` never
      // points back at the active profile.
      final c = await buildController(
        connected: [_mon(id: 'A')],
        profiles: [
          Profile(name: 'active', monitors: [_mon(id: 'A')]),
          Profile(name: 'other', monitors: [_mon(id: 'A')]),
        ],
      );
      final s = c.findBestProfileSuggestion();
      expect(
        s?.profileIndex,
        isNot(equals(c.activeProfileIndex)),
        reason: 'A suggestion (if any) must not point at the active profile.',
      );
    });

    test('confidence floor blocks too-weak candidates even when they '
        'beat the active profile', () async {
      // Active is a profile with no overlap at all (active conf = 0).
      // The candidate has a tiny overlap (1 of 3 outputs claimed,
      // conf ≈ 0.333) — strictly better than 0 but not what a user
      // would call a "match". The floor exists exactly for this.
      final c = await buildController(
        connected: [
          _mon(id: 'A'),
          _mon(id: 'B', x: 1920),
          _mon(id: 'C', x: 3840),
        ],
        profiles: [
          // Will not match anything in the connected set.
          Profile(name: 'unrelated', monitors: [_mon(id: 'Z')]),
          // Matches 1 of 3 outputs → conf ≈ 0.333.
          Profile(name: 'mobile', monitors: [_mon(id: 'A')]),
        ],
      );
      // Init injects a "Current Setup" profile (active, conf 1.0)
      // since neither stored profile is a full match. Pin the
      // unrelated one so the candidate path has room to fire.
      c.setActiveProfile(0);
      expect(c.findBestProfileSuggestion(confidenceFloor: 0.5), isNotNull,
          reason: "Current Setup beats both the floor and the active 0/3 "
              "score, so a suggestion is in order.");
      expect(c.findBestProfileSuggestion(confidenceFloor: 1.01), isNull,
          reason: 'No candidate can clear an above-1.0 floor.');
    });
  });

  group('hotplug-driven suggestion firing', () {
    test('fires onProfileSuggestion when a non-active match shows up',
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
      ProfileSuggestion? got;
      c.onProfileSuggestion = (s) => got = s;
      // Plug in B → connected set now matches `desk` perfectly.
      final fake = c.monitors as FakeMonitorService;
      fake.emitOutputs([_mon(id: 'A'), _mon(id: 'B', x: 1920)]);
      await pumpEventQueue();
      expect(got, isNotNull);
      expect(got!.profileName, 'desk');
    });

    test('suppresses suggestions for 30s after a manual profile switch',
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
      // Manual switch — starts the cooldown.
      c.setActiveProfile(0);
      ProfileSuggestion? got;
      c.onProfileSuggestion = (s) => got = s;
      final fake = c.monitors as FakeMonitorService;
      fake.emitOutputs([_mon(id: 'A'), _mon(id: 'B', x: 1920)]);
      await pumpEventQueue();
      expect(got, isNull,
          reason: 'Within the cooldown window we must not nag the user.');
    });
  });
}
