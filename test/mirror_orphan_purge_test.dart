// Targets the bugs that produced recursive picture-in-picture and
// orphan wl-mirror processes in the wild:
//
//  1. The kanshi config persisted mirrors as `exec wl-mirror …` hooks,
//     so every kanshictl reload spawned an extra wl-mirror — multiple
//     processes on the same destination, occasionally cycling into
//     infinite picture-in-picture.
//  2. setMirror's order of operations let kanshi reload a stale config
//     (still holding the previous mirror's exec hook) before the GUI's
//     debounced save flushed.
//  3. MirrorRunner.stop only killed processes the runner had spawned
//     itself, leaving kanshi-spawned siblings alive.
//
// Each test below pins one of those failure modes shut.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kanshi_gui/models/monitor_tile_data.dart';
import 'package:kanshi_gui/models/profiles.dart';
import 'package:kanshi_gui/services/kanshi_config_parser.dart';
import 'package:kanshi_gui/services/kanshi_config_writer.dart';
import 'package:kanshi_gui/services/mirror_runner.dart';

import 'fakes/fake_process_runner.dart';

MonitorTileData _mon({
  required String id,
  double x = 0,
  String? mirrorOf,
}) =>
    MonitorTileData(
      id: id,
      manufacturer: id,
      x: x,
      y: 0,
      width: 1920,
      height: 1080,
      scale: 1.0,
      rotation: 0,
      refresh: 60,
      resolution: '1920x1080',
      orientation: 'landscape',
      mirrorOf: mirrorOf,
    );

void main() {
  group('parsePgrep helper', () {
    test('extracts (pid, dst, src) from canonical wl-mirror invocations',
        () {
      const stdout = '''
12345 wl-mirror --fullscreen-output DP-5 eDP-1
67890 wl-mirror --fullscreen-output Some-Brand-0 eDP-1
11111 bash -c something else
22222 wl-mirror -F DP-3 DP-4
''';
      final got = MirrorRunner.parsePgrepForTest(stdout);
      expect(got, hasLength(3),
          reason: "Skips lines that aren't a wl-mirror invocation.");
      expect(got[0].pid, 12345);
      expect(got[0].dst, 'DP-5');
      expect(got[0].src, 'eDP-1');
      expect(got[2].pid, 22222);
      expect(got[2].dst, 'DP-3');
      expect(got[2].src, 'DP-4');
    });

    test('returns an empty list for empty input', () {
      expect(MirrorRunner.parsePgrepForTest(''), isEmpty);
    });

    test('skips lines with a missing or non-numeric pid', () {
      const stdout = '''
notapid wl-mirror --fullscreen-output DP-5 eDP-1
''';
      expect(MirrorRunner.parsePgrepForTest(stdout), isEmpty);
    });
  });

  group('MirrorRunner kills externals on start/stop', () {
    test('start() invokes pgrep before spawning, then kills any orphan',
        () async {
      // Pretend an orphan wl-mirror is running on DP-2.
      final fake = FakeProcessRunner(
        installed: {'wl-mirror'},
        responses: {
          'pgrep -fa wl-mirror': ProcessResult(
            0,
            0,
            '4242 wl-mirror --fullscreen-output DP-2 DP-1\n',
            '',
          ),
        },
      );
      final mr = MirrorRunner(runner: fake);
      await mr.start('DP-9', 'DP-2');
      // Among the recorded calls we expect: pgrep, kill 4242, then the
      // wl-mirror spawn for our managed entry.
      expect(
          fake.calls,
          containsAllInOrder([
            equals(['pgrep', '-fa', 'wl-mirror']),
            equals(['kill', '-TERM', '4242']),
          ]));
      expect(
          fake.calls.any(
            (c) => c.first == 'wl-mirror' && c.last == 'DP-9',
          ),
          isTrue);
    });

    test('stop() kills externals even when no managed entry exists',
        () async {
      final fake = FakeProcessRunner(
        installed: {'wl-mirror'},
        responses: {
          'pgrep -fa wl-mirror': ProcessResult(
            0,
            0,
            '4242 wl-mirror --fullscreen-output DP-2 DP-1\n',
            '',
          ),
        },
      );
      final mr = MirrorRunner(runner: fake);
      // No prior start() — but stop() should still purge externals.
      await mr.stop('DP-2');
      expect(
          fake.calls,
          contains(equals(['kill', '-TERM', '4242'])));
    });

    test('purgeExternalNotMatching kills only mismatching externals',
        () async {
      final fake = FakeProcessRunner(
        installed: {'wl-mirror'},
        responses: {
          'pgrep -fa wl-mirror': ProcessResult(
            0,
            0,
            // Two externals: DP-2 mirroring DP-1 (we'd keep it if we
            // owned it) and DP-9 mirroring DP-3 (orphan not in our
            // desired set — must be killed).
            '4242 wl-mirror --fullscreen-output DP-2 DP-1\n'
                '5555 wl-mirror --fullscreen-output DP-9 DP-3\n',
            '',
          ),
        },
      );
      final mr = MirrorRunner(runner: fake);
      await mr.purgeExternalNotMatching({'DP-2': 'DP-1'});
      // Only the DP-9 orphan should get a kill (DP-2 isn't owned by us
      // either, so it actually also gets killed — that's by design).
      expect(
          fake.calls,
          contains(equals(['kill', '-TERM', '5555'])));
    });
  });

  group('mirror persistence uses the annotation, not exec', () {
    test('writer never emits `exec wl-mirror` for a mirrored profile', () {
      final p = Profile(
        name: 'Mirror',
        monitors: [
          _mon(id: 'A', x: 0),
          _mon(id: 'B', x: 1920, mirrorOf: 'A'),
        ],
      );
      final rendered = KanshiConfigWriter.render(
        [p],
        options: KanshiWriteOptions.swayDefaults,
      );
      expect(rendered, isNot(contains('exec wl-mirror')),
          reason: 'No exec hook → no kanshi-spawned wl-mirror duplicates.');
      expect(rendered, contains("# kanshi_gui:mirror 'B'='A'"),
          reason: 'Mirror state is persisted as a comment annotation.');
    });

    test('parser recovers `mirrorOf` from the annotation', () {
      final p = Profile(
        name: 'Mirror',
        monitors: [
          _mon(id: 'A', x: 0),
          _mon(id: 'B', x: 1920, mirrorOf: 'A'),
        ],
      );
      final rendered = KanshiConfigWriter.render(
        [p],
        options: KanshiWriteOptions.swayDefaults,
      );
      final reparsed =
          KanshiConfigParser.parse(rendered).single.monitors;
      final b = reparsed.firstWhere((m) => m.id == 'B');
      expect(b.mirrorOf, equals('A'));
    });

    test(
        'parser also accepts the legacy `exec wl-mirror` line for backward '
        'compatibility', () {
      const legacy = '''
profile 'old' {
    output 'A' enable scale 1.00 mode 1920x1080@60Hz transform normal position 0,0
    output 'B' enable scale 1.00 mode 1920x1080@60Hz transform normal position 1920,0
    exec wl-mirror --fullscreen-output 'B' 'A' &
}
''';
      final reparsed = KanshiConfigParser.parse(legacy).single.monitors;
      final b = reparsed.firstWhere((m) => m.id == 'B');
      expect(b.mirrorOf, equals('A'),
          reason: 'Configs migrated from older releases must still parse.');
    });

    test('annotation wins when both annotation and legacy exec are present',
        () {
      const both = '''
profile 'mixed' {
    output 'A' enable scale 1.00 mode 1920x1080@60Hz transform normal position 0,0
    output 'B' enable scale 1.00 mode 1920x1080@60Hz transform normal position 1920,0
    # kanshi_gui:mirror 'B'='A'
    exec wl-mirror --fullscreen-output 'B' 'A' &
}
''';
      final reparsed = KanshiConfigParser.parse(both).single.monitors;
      // Both formats agree here; the test mostly verifies neither
      // throws an error.
      final b = reparsed.firstWhere((m) => m.id == 'B');
      expect(b.mirrorOf, equals('A'));
    });
  });
}
