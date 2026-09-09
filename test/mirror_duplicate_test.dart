// What happens when a destination ends up with two wl-mirrors.
//
// kanshi runs every exec line of a profile again on each reload, so a config
// with a mirror line produces a second wl-mirror for the same output every
// time the app reloads it. Measured on sway 1.12: the later window takes the
// fullscreen slot, the earlier one is demoted to a tiled window, and when the
// later one dies the survivor stays tiled — a 640 px wide box with the other
// screen's picture in it. That was the "mirror keeps switching itself off"
// from a presentation. These tests pin down what the runner and the
// coordinator do about it.

import 'dart:convert';
import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kanshi_gui/models/monitor_tile_data.dart';
import 'package:kanshi_gui/services/backends/sway_backend.dart';
import 'package:kanshi_gui/services/mirror_runner.dart';
import 'package:kanshi_gui/state/mirror_coordinator.dart';

import 'fakes/fake_mirror_runner.dart';
import 'fakes/fake_monitor_service.dart';
import 'fakes/fake_process_runner.dart';

List<List<String>> _spawns(List<List<String>> calls) =>
    [for (final c in calls) if (c.first == 'wl-mirror') c];

List<List<String>> _kills(List<List<String>> calls) =>
    [for (final c in calls) if (c.first == 'kill') c];

const _pgrep = 'pgrep -fa wl-mirror';

MonitorTileData _mon({required String id, String? mirrorOf}) =>
    MonitorTileData(
      id: id,
      manufacturer: id,
      x: 0,
      y: 0,
      width: 1920,
      height: 1080,
      rotation: 0,
      refresh: 60,
      resolution: '1920x1080',
      orientation: 'landscape',
      mirrorOf: mirrorOf,
    );

void main() {
  group('MirrorRunner and a duplicate on its destination', () {
    test('start() removes the duplicate and relaunches its own process',
        () async {
      final fake = FakeProcessRunner(installed: {'wl-mirror'});
      final mr = MirrorRunner(runner: fake);
      await mr.start('eDP-1', 'DP-1');
      await pumpEventQueue();
      final own = mr.pidFor('DP-1');
      expect(own, isNotNull);

      // kanshi reloaded and started another one.
      fake.responses[_pgrep] = ProcessResult(
        0,
        0,
        '$own wl-mirror --scaling fit --fullscreen-output DP-1 eDP-1\n'
        '20000 wl-mirror --scaling fit --fullscreen-output DP-1 eDP-1\n',
        '',
      );
      await mr.start('eDP-1', 'DP-1');
      await pumpEventQueue();

      expect(_kills(fake.calls), [
        ['kill', '-TERM', '20000']
      ], reason: 'the duplicate goes; our own is replaced via its handle');
      expect(_spawns(fake.calls), hasLength(2),
          reason: 'a fresh process makes a fresh fullscreen request');
      expect(mr.pidFor('DP-1'), isNot(own));
      expect(mr.activeDestinations, {'DP-1'});
    });

    test('start() without a duplicate leaves the process alone', () async {
      final fake = FakeProcessRunner(installed: {'wl-mirror'});
      final mr = MirrorRunner(runner: fake);
      await mr.start('eDP-1', 'DP-1');
      await pumpEventQueue();
      final own = mr.pidFor('DP-1');
      fake.responses[_pgrep] = ProcessResult(
        0,
        0,
        '$own wl-mirror --scaling fit --fullscreen-output DP-1 eDP-1\n',
        '',
      );
      await mr.start('eDP-1', 'DP-1');
      expect(_spawns(fake.calls), hasLength(1));
      expect(_kills(fake.calls), isEmpty);
      expect(mr.pidFor('DP-1'), own);
    });

    test('the purge sweep treats a duplicate on an owned destination the same',
        () async {
      final fake = FakeProcessRunner(installed: {'wl-mirror'});
      final mr = MirrorRunner(runner: fake);
      await mr.start('eDP-1', 'DP-1');
      await pumpEventQueue();
      final own = mr.pidFor('DP-1');
      fake.responses[_pgrep] = ProcessResult(
        0,
        0,
        '$own wl-mirror --scaling fit --fullscreen-output DP-1 eDP-1\n'
        '20000 wl-mirror --scaling fit --fullscreen-output DP-1 eDP-1\n'
        '30000 wl-mirror --scaling fit --fullscreen-output HDMI-A-1 eDP-1\n',
        '',
      );
      await mr.purgeExternalNotMatching({'DP-1': 'eDP-1'});
      await pumpEventQueue();

      expect(_kills(fake.calls), containsAll([
        ['kill', '-TERM', '20000'],
        ['kill', '-TERM', '30000'],
      ]));
      expect(_kills(fake.calls), hasLength(2));
      expect(_spawns(fake.calls), hasLength(2),
          reason: 'DP-1 relaunched once; the orphan on HDMI-A-1 is just gone');
      expect(mr.activeDestinations, {'DP-1'});
    });

    test('a relaunch does not count against the retry budget', () async {
      // Three relaunches in a row must not mark the destination failed:
      // they are the runner's own doing, not crashes.
      final fake = FakeProcessRunner(installed: {'wl-mirror'});
      final mr = MirrorRunner(runner: fake);
      await mr.start('eDP-1', 'DP-1');
      for (var i = 0; i < 4; i++) {
        await pumpEventQueue();
        fake.responses[_pgrep] = ProcessResult(
          0,
          0,
          '${mr.pidFor('DP-1')} wl-mirror --fullscreen-output DP-1 eDP-1\n'
          '${40000 + i} wl-mirror --fullscreen-output DP-1 eDP-1\n',
          '',
        );
        await mr.start('eDP-1', 'DP-1');
      }
      expect(mr.failedDestinations, isEmpty);
      expect(mr.activeDestinations, {'DP-1'});
    });
  });

  group('MirrorCoordinator.heal', () {
    test('asks the backend to keep every owned window fullscreen', () async {
      final runner = FakeMirrorRunner();
      final monitors = FakeMonitorService(supportsMirror: true);
      final coordinator = MirrorCoordinator(monitors, runner);
      await runner.start('eDP-1', 'DP-1');
      await runner.start('eDP-1', 'HDMI-A-1');
      runner.pids['DP-1'] = 111;
      // HDMI-A-1 has no pid yet: the spawn is still resolving.
      await coordinator.heal();
      expect(monitors.ensureFullscreenCalls, [111]);
    });

    test('runs on its own while a mirror is up, and stops when none is',
        () {
      fakeAsync((async) {
        final runner = FakeMirrorRunner();
        final monitors = FakeMonitorService(supportsMirror: true);
        final coordinator = MirrorCoordinator(monitors, runner);
        final live = [_mon(id: 'eDP-1'), _mon(id: 'DP-1')];
        final profile = [_mon(id: 'eDP-1'), _mon(id: 'DP-1', mirrorOf: 'eDP-1')];

        coordinator.reconcile(
          supportsMirror: true,
          profileMonitors: profile,
          liveOutputs: live,
          resolveConnector: (id) => id,
        );
        async.flushMicrotasks();
        runner.pids['DP-1'] = 222;
        async.elapse(MirrorCoordinator.watchInterval * 2);
        expect(monitors.ensureFullscreenCalls, [222, 222],
            reason: 'one check per interval while the mirror is up');

        // The mirror is released: the watch has nothing to do and ends.
        coordinator.reconcile(
          supportsMirror: true,
          profileMonitors: [_mon(id: 'eDP-1'), _mon(id: 'DP-1')],
          liveOutputs: live,
          resolveConnector: (id) => id,
        );
        async.flushMicrotasks();
        monitors.ensureFullscreenCalls.clear();
        async.elapse(MirrorCoordinator.watchInterval * 3);
        expect(monitors.ensureFullscreenCalls, isEmpty);
        coordinator.dispose();
      });
    });
  });

  group('SwayBackend.ensureFullscreen', () {
    Map<String, dynamic> tree(int mode) => {
          'type': 'root',
          'nodes': [
            {
              'type': 'output',
              'name': 'DP-1',
              'nodes': [
                {
                  'type': 'workspace',
                  'nodes': [
                    {'type': 'con', 'pid': 4321, 'fullscreen_mode': 0},
                    {'type': 'con', 'pid': 1234, 'fullscreen_mode': mode},
                  ],
                  'floating_nodes': <Object>[],
                }
              ],
            }
          ],
        };

    test('finds the view by pid anywhere in the tree', () {
      expect(SwayBackend.fullscreenModeOfPid(1234, tree(1)), 1);
      expect(SwayBackend.fullscreenModeOfPid(4321, tree(1)), 0);
      expect(SwayBackend.fullscreenModeOfPid(9, tree(1)), isNull);
    });

    test('re-enables fullscreen only when the view lost it', () async {
      Future<List<List<String>>> run(int mode) async {
        final fake = FakeProcessRunner(
          installed: {'swaymsg'},
          responses: {
            'swaymsg -t get_tree':
                ProcessResult(0, 0, jsonEncode(tree(mode)), ''),
          },
        );
        final sway = SwayBackend(runner: fake);
        expect(await sway.ensureFullscreen(1234), isTrue);
        return fake.calls;
      }

      expect(await run(1),
          isNot(anyElement(equals(['swaymsg', '[pid=1234]', 'fullscreen', 'enable']))));
      expect(await run(0),
          anyElement(equals(['swaymsg', '[pid=1234]', 'fullscreen', 'enable'])));
    });

    test('a pid without a window is reported, not repaired', () async {
      final fake = FakeProcessRunner(
        installed: {'swaymsg'},
        responses: {
          'swaymsg -t get_tree': ProcessResult(0, 0, jsonEncode(tree(1)), ''),
        },
      );
      final sway = SwayBackend(runner: fake);
      expect(await sway.ensureFullscreen(9), isFalse);
      expect(fake.calls, hasLength(1));
    });
  });
}
