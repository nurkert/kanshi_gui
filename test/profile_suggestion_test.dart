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

    test('exact id match on a different profile scores 1.0', () async {
      final c = await buildController(
        connected: [_mon(id: 'A'), _mon(id: 'B', x: 1920)],
        profiles: [
          Profile(
            name: 'desk',
            monitors: [_mon(id: 'A'), _mon(id: 'B', x: 1920)],
          ),
          // Same outputs, different name — both match the connected set.
          Profile(
            name: 'desk-alt',
            monitors: [_mon(id: 'A'), _mon(id: 'B', x: 1920)],
          ),
        ],
      );
      // 'desk' is auto-picked (first match wins). 'desk-alt' is the
      // only other candidate.
      final s = c.findBestProfileSuggestion();
      expect(s, isNotNull);
      expect(s!.profileName, 'desk-alt');
      expect(s.confidence, equals(1.0));
      expect(s.matchedOutputs, 2);
      expect(s.totalOutputs, 2);
    });


    test('partial match degrades confidence proportionally', () async {
      // Connected has 3 outputs; the candidate profile has 2 — only 2
      // matches possible, denom = max(2, 3) = 3, confidence = 2/3.
      final c = await buildController(
        connected: [
          _mon(id: 'A'),
          _mon(id: 'B', x: 1920),
          _mon(id: 'C', x: 3840),
        ],
        profiles: [
          // Active: matches the full set exactly.
          Profile(
            name: 'triple',
            monitors: [
              _mon(id: 'A'),
              _mon(id: 'B', x: 1920),
              _mon(id: 'C', x: 3840),
            ],
          ),
          // Candidate: subset of two outputs.
          Profile(
            name: 'docked',
            monitors: [_mon(id: 'A'), _mon(id: 'B', x: 1920)],
          ),
        ],
      );
      final s = c.findBestProfileSuggestion();
      expect(s, isNotNull);
      expect(s!.profileName, 'docked');
      expect(s.confidence, closeTo(2 / 3, 0.001));
      expect(s.matchedOutputs, 2);
      expect(s.totalOutputs, 3);
    });

    test('does not suggest the currently active profile', () async {
      final c = await buildController(
        connected: [_mon(id: 'A')],
        profiles: [
          Profile(name: 'active', monitors: [_mon(id: 'A')]),
          Profile(name: 'other', monitors: [_mon(id: 'A')]),
        ],
      );
      // Both profiles match. Active is index 0; suggestion must be 1.
      final s = c.findBestProfileSuggestion();
      expect(s, isNotNull);
      expect(s!.profileIndex, equals(1));
    });

    test('confidence floor prunes weaker partial matches', () async {
      // Partial-match: candidate has 2 outputs but the live system has 3,
      // so confidence floors at 2/3 ≈ 0.667. With a 0.8 floor it should
      // be pruned; with 0.5 it should pass.
      final c = await buildController(
        connected: [
          _mon(id: 'A'),
          _mon(id: 'B', x: 1920),
          _mon(id: 'C', x: 3840),
        ],
        profiles: [
          Profile(
            name: 'triple',
            monitors: [
              _mon(id: 'A'),
              _mon(id: 'B', x: 1920),
              _mon(id: 'C', x: 3840),
            ],
          ),
          Profile(
            name: 'docked',
            monitors: [_mon(id: 'A'), _mon(id: 'B', x: 1920)],
          ),
        ],
      );
      expect(c.findBestProfileSuggestion(confidenceFloor: 0.8), isNull,
          reason: '2/3 confidence does not clear an 0.8 floor.');
      expect(c.findBestProfileSuggestion(confidenceFloor: 0.5), isNotNull,
          reason: '2/3 confidence comfortably clears the default 0.5 floor.');
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
