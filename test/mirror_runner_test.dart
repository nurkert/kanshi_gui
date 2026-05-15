import 'package:flutter_test/flutter_test.dart';
import 'package:kanshi_gui/services/mirror_runner.dart';

import 'fakes/fake_process_runner.dart';

/// Filters [calls] down to just the wl-mirror invocations, dropping
/// `pgrep` / `kill` bookkeeping the runner does to clean up external
/// processes. Lets tests assert on the spawn pattern without coupling
/// to the orphan-purge plumbing.
List<List<String>> _wlMirrorOnly(List<List<String>> calls) =>
    [for (final c in calls) if (c.first == 'wl-mirror') c];

void main() {
  group('MirrorRunner.isAvailable', () {
    test('true when wl-mirror is in PATH', () async {
      final runner = MirrorRunner(
        runner: FakeProcessRunner(installed: {'wl-mirror'}),
      );
      expect(await runner.isAvailable(), isTrue);
    });

    test('false when wl-mirror is missing', () async {
      final runner = MirrorRunner(runner: FakeProcessRunner());
      expect(await runner.isAvailable(), isFalse);
    });
  });

  group('MirrorRunner.start / stop', () {
    test('spawns wl-mirror with --fullscreen-output flag and source last',
        () async {
      // wl-mirror's CLI requires the source positional to be the last
      // argument. We assert the exact order so a regression to "src first
      // / fullscreen flag last" gets caught.
      final fake = FakeProcessRunner(installed: {'wl-mirror'});
      final mr = MirrorRunner(runner: fake);
      await mr.start('DP-1', 'DP-2');
      final spawns = _wlMirrorOnly(fake.calls);
      expect(spawns, hasLength(1));
      expect(
          spawns.single,
          equals([
            'wl-mirror',
            '--scaling',
            'fit',
            '--fullscreen-output',
            'DP-2',
            'DP-1',
          ]),
          reason: '--scaling fit is wl-mirror\'s documented default but we '
              'pass it explicitly so the rendering can\'t regress to a '
              'cropped/cover mode if the default ever changes.');
      expect(mr.activeDestinations, equals({'DP-2'}));
      expect(mr.mirrorSourceFor('DP-2'), equals('DP-1'));
    });

    test('start with same (src, dst) is a no-op', () async {
      final fake = FakeProcessRunner(installed: {'wl-mirror'});
      final mr = MirrorRunner(runner: fake);
      await mr.start('DP-1', 'DP-2');
      await mr.start('DP-1', 'DP-2');
      expect(_wlMirrorOnly(fake.calls), hasLength(1),
          reason: 'Second start must not respawn wl-mirror.');
    });

    test('start with new src on the same dst restarts wl-mirror', () async {
      final fake = FakeProcessRunner(installed: {'wl-mirror'});
      final mr = MirrorRunner(runner: fake);
      await mr.start('DP-1', 'DP-2');
      await mr.start('DP-3', 'DP-2');
      final spawns = _wlMirrorOnly(fake.calls);
      expect(spawns, hasLength(2));
      expect(spawns.last.last, equals('DP-3'),
          reason: 'New src must be the trailing positional.');
      expect(mr.mirrorSourceFor('DP-2'), equals('DP-3'));
    });

    test('stop removes the destination and prevents respawn', () async {
      final fake = FakeProcessRunner(installed: {'wl-mirror'});
      final mr = MirrorRunner(runner: fake);
      await mr.start('DP-1', 'DP-2');
      await mr.stop('DP-2');
      expect(mr.activeDestinations, isEmpty);
      // Closing the (now-detached) controller must not trigger a respawn.
      fake.openStream('wl-mirror --scaling fit --fullscreen-output DP-2 DP-1').close();
      await Future<void>.delayed(Duration.zero);
      expect(_wlMirrorOnly(fake.calls), hasLength(1),
          reason: 'After stop, an exit on the stream must NOT respawn.');
    });

    test('stopAll kills every active destination', () async {
      final fake = FakeProcessRunner(installed: {'wl-mirror'});
      final mr = MirrorRunner(runner: fake);
      await mr.start('DP-1', 'DP-2');
      await mr.start('DP-1', 'DP-3');
      expect(mr.activeDestinations, hasLength(2));
      await mr.stopAll();
      expect(mr.activeDestinations, isEmpty);
    });
  });

  group('MirrorRunner auto-respawn', () {
    test('unintended exit triggers a respawn (within retry budget)',
        () async {
      final fake = FakeProcessRunner(installed: {'wl-mirror'});
      final mr = MirrorRunner(runner: fake);
      await mr.start('DP-1', 'DP-2');
      // Simulate wl-mirror dying (e.g. user closed the fullscreen window).
      final key = 'wl-mirror --scaling fit --fullscreen-output DP-2 DP-1';
      await fake.openStream(key).close();
      await Future<void>.delayed(Duration.zero);
      expect(_wlMirrorOnly(fake.calls), hasLength(2),
          reason: 'Runner must respawn wl-mirror after an unintended exit.');
      expect(mr.activeDestinations, contains('DP-2'));
    });

    test('exhausting the retry budget marks the destination failed',
        () async {
      var clock = DateTime(2026, 5, 5, 12, 0, 0);
      final fake = FakeProcessRunner(installed: {'wl-mirror'});
      final mr = MirrorRunner(runner: fake, now: () => clock);
      await mr.start('DP-1', 'DP-2');
      const key = 'wl-mirror --scaling fit --fullscreen-output DP-2 DP-1';

      // Three rapid back-to-back deaths within the 30 s window. The
      // budget is 3, so the fourth death marks DP-2 failed.
      for (var i = 0; i < 4; i++) {
        await fake.openStream(key).close();
        await Future<void>.delayed(Duration.zero);
        clock = clock.add(const Duration(seconds: 2));
      }
      expect(mr.failedDestinations, contains('DP-2'));
      expect(mr.activeDestinations, isNot(contains('DP-2')));
    });

    test('a death after the retry window resets the budget', () async {
      var clock = DateTime(2026, 5, 5, 12, 0, 0);
      final fake = FakeProcessRunner(installed: {'wl-mirror'});
      final mr = MirrorRunner(runner: fake, now: () => clock);
      await mr.start('DP-1', 'DP-2');
      const key = 'wl-mirror --scaling fit --fullscreen-output DP-2 DP-1';

      // First death and respawn.
      await fake.openStream(key).close();
      await Future<void>.delayed(Duration.zero);
      // Wait beyond the retry window before the next death.
      clock = clock.add(const Duration(seconds: 31));
      await fake.openStream(key).close();
      await Future<void>.delayed(Duration.zero);

      // Two deaths total but neither came inside a retry window after the
      // other → still respawning, never failed.
      expect(mr.failedDestinations, isEmpty);
      expect(mr.activeDestinations, contains('DP-2'));
    });

    test('clearFailure removes the failed flag', () async {
      var clock = DateTime(2026, 5, 5, 12, 0, 0);
      final fake = FakeProcessRunner(installed: {'wl-mirror'});
      final mr = MirrorRunner(runner: fake, now: () => clock);
      await mr.start('DP-1', 'DP-2');
      const key = 'wl-mirror --scaling fit --fullscreen-output DP-2 DP-1';
      for (var i = 0; i < 4; i++) {
        await fake.openStream(key).close();
        await Future<void>.delayed(Duration.zero);
      }
      expect(mr.failedDestinations, contains('DP-2'));
      mr.clearFailure('DP-2');
      expect(mr.failedDestinations, isEmpty);
    });
  });
}
