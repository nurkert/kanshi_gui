// What two independent reviews of the 2.3.3 mirror work found, pinned.

import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kanshi_gui/models/monitor_tile_data.dart';
import 'package:kanshi_gui/models/profiles.dart';
import 'package:kanshi_gui/services/config_service.dart';
import 'package:kanshi_gui/services/kanshi_config_parser.dart';
import 'package:kanshi_gui/services/kanshi_config_writer.dart';
import 'package:kanshi_gui/services/mirror_runner.dart';
import 'package:kanshi_gui/state/kanshi_controller.dart';
import 'package:kanshi_gui/state/mirror_coordinator.dart';

import 'fakes/fake_mirror_runner.dart';
import 'fakes/fake_monitor_service.dart';
import 'fakes/fake_process_runner.dart';
import 'support/kanshi_exec.dart';

const _pgrep = 'pgrep -fa wl-mirror';

List<List<String>> _spawns(List<List<String>> calls) =>
    [for (final c in calls) if (c.first == 'wl-mirror') c];

List<List<String>> _kills(List<List<String>> calls) =>
    [for (final c in calls) if (c.first == 'kill') c];

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
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('kanshi_review_'));
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('MirrorRunner', () {
    test('does not mistake its own fresh process for a duplicate', () async {
      // The pid of a spawn arrives a moment after the spawn. A second
      // start() in that moment used to scan the process table, see a
      // wl-mirror it could not account for, and kill its own child.
      final fake = FakeProcessRunner(installed: {'wl-mirror'})
        ..pidDelay = const Duration(milliseconds: 40);
      final mr = MirrorRunner(runner: fake);
      await mr.start('eDP-1', 'DP-1');
      expect(mr.pidFor('DP-1'), isNull, reason: 'the pid is still on its way');
      fake.responses[_pgrep] = ProcessResult(
        0,
        0,
        '10000 wl-mirror --scaling fit --fullscreen-output DP-1 eDP-1\n',
        '',
      );
      await mr.start('eDP-1', 'DP-1');
      expect(_kills(fake.calls), isEmpty);
      expect(_spawns(fake.calls), hasLength(1));
      expect(mr.pidFor('DP-1'), 10000);
    });

    test('a stop() during a relaunch wins; nothing is spawned untracked',
        () async {
      final fake = FakeProcessRunner(installed: {'wl-mirror'});
      final mr = MirrorRunner(runner: fake);
      await mr.start('eDP-1', 'DP-1');
      await pumpEventQueue();
      fake.responses[_pgrep] = ProcessResult(
        0,
        0,
        '${mr.pidFor('DP-1')} wl-mirror --fullscreen-output DP-1 eDP-1\n'
        '20000 wl-mirror --fullscreen-output DP-1 eDP-1\n',
        '',
      );
      final relaunch = mr.start('eDP-1', 'DP-1');
      final stopped = mr.stop('DP-1');
      await Future.wait([relaunch, stopped]);
      await pumpEventQueue();
      expect(mr.activeDestinations, isEmpty);
      expect(_spawns(fake.calls), hasLength(1),
          reason: 'the relaunch must notice the stop and not spawn');
    });
  });

  group('MirrorCoordinator', () {
    test('the watch ends when the runner drops the mirror on its own', () {
      fakeAsync((async) {
        final runner = FakeMirrorRunner();
        final monitors = FakeMonitorService(supportsMirror: true);
        final coordinator = MirrorCoordinator(monitors, runner);
        final live = [_mon(id: 'eDP-1'), _mon(id: 'DP-1')];
        coordinator.reconcile(
          supportsMirror: true,
          profileMonitors: [_mon(id: 'eDP-1'), _mon(id: 'DP-1', mirrorOf: 'eDP-1')],
          liveOutputs: live,
          resolveConnector: (id) => id,
        );
        async.flushMicrotasks();
        runner.pids['DP-1'] = 5;
        async.elapse(MirrorCoordinator.watchInterval);
        expect(monitors.ensureFullscreenCalls, [5]);

        // A crash that exhausts the retry budget: no reconcile, the runner
        // just announces the destination is gone.
        runner.stop('DP-1');
        async.flushMicrotasks();
        monitors.ensureFullscreenCalls.clear();
        async.elapse(MirrorCoordinator.watchInterval * 3);
        expect(monitors.ensureFullscreenCalls, isEmpty);
        coordinator.dispose();
      });
    });

    test('nothing ticks after dispose, even with a reconcile in flight', () {
      fakeAsync((async) {
        final runner = FakeMirrorRunner();
        final monitors = FakeMonitorService(supportsMirror: true);
        final coordinator = MirrorCoordinator(monitors, runner);
        final live = [_mon(id: 'eDP-1'), _mon(id: 'DP-1')];
        coordinator.reconcile(
          supportsMirror: true,
          profileMonitors: [_mon(id: 'eDP-1'), _mon(id: 'DP-1', mirrorOf: 'eDP-1')],
          liveOutputs: live,
          resolveConnector: (id) => id,
        );
        coordinator.dispose();
        async.flushMicrotasks();
        runner.pids['DP-1'] = 5;
        async.elapse(MirrorCoordinator.watchInterval * 3);
        expect(monitors.ensureFullscreenCalls, isEmpty);
      });
    });
  });

  group('KanshiController.setMirror', () {
    test('refuses a destination that is feeding another screen', () async {
      // A → B with C already showing B would be a chain, which wl-mirror
      // does not follow.
      // Sway options: the mirror annotation is only written on the backend
      // that can mirror, and the chain check reads the loaded profile.
      final config = ConfigService(
        configPath: '${tmp.path}/config',
        backupPrefix: '${tmp.path}/config.bak',
        writeOptions: KanshiWriteOptions.swayDefaults,
      );
      final mons = [
        _mon(id: 'eDP-1', x: 0),
        _mon(id: 'DP-1', x: 1920, mirrorOf: 'eDP-1'),
        _mon(id: 'HDMI-A-1', x: 3840),
      ];
      await config.saveProfiles([Profile(name: 'Talk', monitors: mons)]);
      final c = KanshiController(
        monitors: FakeMonitorService(supportsMirror: true, outputs: mons),
        config: config,
        mirrorRunner: FakeMirrorRunner(),
      );
      await c.init();
      final r = await c.setMirror('eDP-1', 'HDMI-A-1');
      expect(r.success, isFalse);
      expect(r.message, contains('stop that mirror first'));
      expect(c.activeMonitors.firstWhere((m) => m.id == 'eDP-1').mirrorOf,
          isNull);
    });
  });

  group('ConfigService, saving in place', () {
    test('recognises its own launcher line and does not double it',
        () async {
      final config = ConfigService(
        configPath: '${tmp.path}/config',
        backupPrefix: '${tmp.path}/config.bak',
        writeOptions: KanshiWriteOptions.swayDefaults
            .copyWith(useMirrorLauncher: true),
      );
      final mons = [
        _mon(id: 'eDP-1', x: 0),
        _mon(id: 'DP-1', x: 1920, mirrorOf: 'eDP-1'),
      ];
      await config.saveProfiles([Profile(name: 'Talk', monitors: mons)]);
      await config.saveProfiles([Profile(name: 'Talk', monitors: mons)]);
      await config.saveProfiles([
        Profile(name: 'Talk', monitors: [
          mons.first,
          mons.last.copyWith(mirrorOf: null),
        ]),
      ]);
      final lines = File('${tmp.path}/config').readAsLinesSync();
      expect(lines.where((l) => l.contains('kanshi-gui-mirror')), isEmpty,
          reason: 'after the mirror is released no launcher line remains; '
              'a save that did not recognise the line would have kept it');
    });
  });

  group('KanshiConfigParser', () {
    test('reads the launcher exec line back when the annotation is gone', () {
      const cfg = '''
profile 'Talk' {
    output 'eDP-1' enable scale 1.00 mode 1920x1080@60Hz transform normal position 0,0
    output 'DP-1' enable scale 1.00 mode 1920x1080@60Hz transform normal position 3920,0
    exec kanshi-gui-mirror "DP-1" "eDP-1" fit
}
''';
      final p = KanshiConfigParser.parse(cfg).single;
      expect(p.monitors.firstWhere((m) => m.id == 'DP-1').mirrorOf, 'eDP-1');
      expect(p.monitors.firstWhere((m) => m.id == 'eDP-1').mirrorOf, isNull);
    });
  });

  group('kanshi-gui-mirror, with its real pgrep pattern', () {
    final script = File('bin/kanshi-gui-mirror');

    /// Runs the script with a pgrep that greps the given process lines with
    /// the pattern the script hands it, so the pattern itself is on trial.
    Future<KanshiExecResult> run(String line, List<String> procs) {
      final bin = Directory('${tmp.path}/bin')..createSync(recursive: true);
      File('${bin.path}/kanshi-gui-mirror')
          .writeAsStringSync(script.readAsStringSync());
      Process.runSync('chmod', ['755', '${bin.path}/kanshi-gui-mirror']);
      File('${tmp.path}/procs').writeAsStringSync('${procs.join('\n')}\n');
      // pgrep -f -- PATTERN matches command lines (no pid in front); the
      // pattern is the last argument, HOME is the
      // sandbox (runAsKanshiWould sets it).
      File('${bin.path}/pgrep').writeAsStringSync(
          '#!/bin/sh\neval "pat=\\\${\$#}"\ngrep -E -q -- "\$pat" "\$HOME/procs"\n');
      Process.runSync('chmod', ['755', '${bin.path}/pgrep']);
      // pkill is a stub that only records what it was asked to kill.
      return runAsKanshiWould(line,
          sandbox: tmp, stubs: const ['wl-mirror', 'pkill']);
    }

    test('a mirror onto the destination from another source is replaced',
        () async {
      final r = await run('exec kanshi-gui-mirror "DP-1" "eDP-1" fit', [
        'wl-mirror --scaling fit --fullscreen-output DP-1 HDMI-A-1',
      ]);
      expect(r.failed, isFalse, reason: r.stderr);
      expect(r.invocations.map((i) => i.first), ['pkill', 'wl-mirror'],
          reason: 'the stale one goes first, then the one the config asks for');
      expect(r.invocations.first, contains('-TERM'));
      expect(r.invocations.last.last, 'eDP-1');
    });

    test('sees a running mirror for the destination', () async {
      final r = await run('exec kanshi-gui-mirror "DP-1" "eDP-1" fit', [
        '/usr/bin/wl-mirror --scaling fit --fullscreen-output DP-1 eDP-1',
      ]);
      expect(r.failed, isFalse, reason: r.stderr);
      expect(r.invocations, isEmpty);
    });

    test('a mirror on DP-11 is not a mirror on DP-1', () async {
      final r = await run('exec kanshi-gui-mirror "DP-1" "eDP-1" fit', [
        'wl-mirror --scaling fit --fullscreen-output DP-11 eDP-1',
        'wl-mirror-something --fullscreen-output DP-1 eDP-1',
      ]);
      expect(r.failed, isFalse, reason: r.stderr);
      expect(r.invocations.map((i) => i.first), ['wl-mirror'],
          reason: 'nothing to replace, nothing to skip: just start');
    });

    test('a dot in the name is a dot, not any character', () async {
      final r = await run('exec kanshi-gui-mirror "DP-1.1" "eDP-1" fit', [
        'wl-mirror --scaling fit --fullscreen-output DP-1x1 eDP-1',
      ]);
      expect(r.failed, isFalse, reason: r.stderr);
      expect(r.invocations.map((i) => i.first), ['wl-mirror'],
          reason: 'DP-1x1 must neither satisfy nor be killed for DP-1.1');
    });
  });
}
