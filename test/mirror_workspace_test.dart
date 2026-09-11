// The mirror's own workspace, and the two automations that used to fight
// over the destination's workspaces.
//
// From a docked desk: the left screen was to show the middle one. wl-mirror's
// window landed on the fresh workspace sway had numbered 4, the workspace
// rule assigns 4 to the laptop, and the helper's next repair walk moved
// workspace 4 to the laptop with the mirror inside it. The destination was
// left showing an empty "10".

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kanshi_gui/domain/mirror_geometry.dart';
import 'package:kanshi_gui/models/monitor_tile_data.dart';
import 'package:kanshi_gui/models/profiles.dart';
import 'package:kanshi_gui/services/app_settings.dart';
import 'package:kanshi_gui/services/backends/sway_backend.dart';
import 'package:kanshi_gui/services/config_service.dart';
import 'package:kanshi_gui/services/kanshi_config_writer.dart';
import 'package:kanshi_gui/services/workspace_daemon_core.dart';
import 'package:kanshi_gui/state/kanshi_controller.dart';
import 'package:kanshi_gui/state/mirror_coordinator.dart';

import 'fakes/fake_mirror_runner.dart';
import 'fakes/fake_monitor_service.dart';
import 'fakes/fake_process_runner.dart';
import 'fakes/fake_sway.dart';

MonitorTileData _mon({
  required String id,
  double x = 0,
  String? mirrorOf,
}) =>
    MonitorTileData(
      id: id,
      manufacturer: 'Panel $id',
      edidDescriptor: 'Make $id Serial$id',
      x: x,
      y: 0,
      width: 2560,
      height: 1440,
      scale: 1.0,
      rotation: 0,
      refresh: 60,
      resolution: '2560x1440',
      orientation: 'landscape',
      enabled: true,
      mirrorOf: mirrorOf,
    );

void main() {
  group('MirrorGeometry.workspaceName', () {
    test('names the workspace after what it shows, and knows its own', () {
      expect(MirrorGeometry.workspaceName('DP-5'), '⇄ DP-5');
      expect(MirrorGeometry.isMirrorWorkspace('⇄ DP-5'), isTrue);
      expect(MirrorGeometry.isMirrorWorkspace('4'), isFalse);
      expect(MirrorGeometry.isMirrorWorkspace('⇄'), isFalse);
      expect(MirrorGeometry.isMirrorWorkspace('4: ⇄ DP-5'), isFalse);
    });
  });

  group('SwayBackend.prepareMirrorWorkspace', () {
    const wsJson = '''
[
  {"num": 2, "name": "2", "output": "DP-5", "focused": true, "visible": true},
  {"num": 10, "name": "10", "output": "DP-4", "focused": false, "visible": true}
]
''';

    test('declares, creates on the destination, hands focus back', () async {
      final fake = FakeProcessRunner(installed: {'swaymsg'}, responses: {
        'swaymsg -t get_workspaces': ProcessResult(0, 0, wsJson, ''),
      });
      await SwayBackend(runner: fake)
          .prepareMirrorWorkspace(output: 'DP-4', name: '⇄ DP-5');
      final sent = [for (final c in fake.calls) if (c.length == 2) c[1]];
      expect(sent, [
        'workspace "⇄ DP-5" output DP-4',
        'workspace "⇄ DP-5"; move workspace to output DP-4; workspace number 2',
      ]);
    });

    test('an existing, shown workspace is only re-declared', () async {
      const shown = '''
[
  {"num": 2, "name": "2", "output": "DP-5", "focused": true, "visible": true},
  {"num": -1, "name": "⇄ DP-5", "output": "DP-4", "focused": false, "visible": true}
]
''';
      final fake = FakeProcessRunner(installed: {'swaymsg'}, responses: {
        'swaymsg -t get_workspaces': ProcessResult(0, 0, shown, ''),
      });
      await SwayBackend(runner: fake)
          .prepareMirrorWorkspace(output: 'DP-4', name: '⇄ DP-5');
      final sent = [for (final c in fake.calls) if (c.length == 2) c[1]];
      expect(sent, ['workspace "⇄ DP-5" output DP-4'],
          reason: 'no focus change for a workspace that is already there');
    });
  });

  group('SwayBackend and the mirror workspace', () {
    const wsJson = '''
[
  {"num": 1, "name": "1", "output": "DP-5", "focused": true},
  {"num": 4, "name": "4", "output": "DP-4", "focused": false},
  {"num": -1, "name": "⇄ DP-5", "output": "DP-4", "focused": false}
]
''';

    test('evacuation leaves it on the destination', () async {
      final fake = FakeProcessRunner(installed: {'swaymsg'}, responses: {
        'swaymsg -t get_workspaces': ProcessResult(0, 0, wsJson, ''),
      });
      await SwayBackend(runner: fake)
          .evacuateOutputWorkspaces('DP-4', ['DP-5']);
      expect(fake.calls[1][1],
          "workspace number 4; move workspace to output 'DP-5'; workspace number 1");
    });

    test('the destination counts as clear with only it there', () async {
      const onlyMirror = '''
[
  {"num": 1, "name": "1", "output": "DP-5", "focused": true},
  {"num": -1, "name": "⇄ DP-5", "output": "DP-4", "focused": false}
]
''';
      final fake = FakeProcessRunner(installed: {'swaymsg'}, responses: {
        'swaymsg -t get_workspaces': ProcessResult(0, 0, onlyMirror, ''),
      });
      expect(await SwayBackend(runner: fake).waitForOutputClear('DP-4'),
          isTrue);
    });
  });

  group('MirrorCoordinator', () {
    test('gives a new mirror its workspace before starting wl-mirror',
        () async {
      final runner = FakeMirrorRunner();
      final monitors = FakeMonitorService(supportsMirror: true);
      final coordinator = MirrorCoordinator(monitors, runner);
      final live = [_mon(id: 'DP-4'), _mon(id: 'DP-5'), _mon(id: 'eDP-1')];
      await coordinator.reconcile(
        supportsMirror: true,
        profileMonitors: [
          _mon(id: 'DP-4', mirrorOf: 'DP-5'),
          _mon(id: 'DP-5'),
          _mon(id: 'eDP-1'),
        ],
        liveOutputs: live,
        resolveConnector: (id) => id,
      );
      expect(monitors.preparedMirrorWorkspaces,
          [(output: 'DP-4', name: '⇄ DP-5')]);
      final order = monitors.calls.indexOf('prepareMirrorWorkspace DP-4 ⇄ DP-5');
      expect(order, greaterThanOrEqualTo(0));
      expect(monitors.calls.indexOf('evacuateOutputWorkspaces'), lessThan(order),
          reason: 'evacuate first, then the mirror workspace, then spawn');
      expect(runner.calls, ['start DP-5 -> DP-4']);

      // A second reconcile finds the mirror running: nothing to prepare.
      await coordinator.reconcile(
        supportsMirror: true,
        profileMonitors: [
          _mon(id: 'DP-4', mirrorOf: 'DP-5'),
          _mon(id: 'DP-5'),
          _mon(id: 'eDP-1'),
        ],
        liveOutputs: live,
        resolveConnector: (id) => id,
      );
      expect(monitors.preparedMirrorWorkspaces, hasLength(1));
      coordinator.dispose();
    });

    test('heal names the destination the compositor knows', () async {
      final runner = FakeMirrorRunner();
      final monitors = FakeMonitorService(supportsMirror: true);
      final coordinator = MirrorCoordinator(monitors, runner);
      // The setup addresses the television by a stable id; the compositor
      // knows it as a port. heal must speak the port.
      await coordinator.reconcile(
        supportsMirror: true,
        profileMonitors: [_mon(id: 'TV', mirrorOf: 'eDP-1'), _mon(id: 'eDP-1')],
        liveOutputs: [_mon(id: 'TV'), _mon(id: 'eDP-1')],
        resolveConnector: (id) => id == 'TV' ? 'HDMI-A-1' : id,
      );
      runner.pids['TV'] = 77;
      await coordinator.heal();
      expect(monitors.calls, contains('ensureMirrorWindow 77 HDMI-A-1 ⇄ eDP-1'));
      coordinator.dispose();
    });
  });

  group('WorkspaceDaemonCore.noteMove', () {
    test('a move while an apply holds the lock is not the user\'s', () async {
      var held = false;
      final sway = FakeSway(
        live: [_mon(id: 'DP-4'), _mon(id: 'DP-5'), _mon(id: 'eDP-1')],
        workspaces: {1: 'DP-4', 2: 'DP-5'},
        focused: 1,
      )..echoChurn = false;
      final env = FakeEnvironment(
        mode: WorkspaceManagementMode.interleaved,
        knownProfiles: [
          Profile(name: 'Office', monitors: [
            _mon(id: 'DP-4', x: 0),
            _mon(id: 'DP-5', x: 2560),
            _mon(id: 'eDP-1', x: 5120),
          ]),
        ],
      );
      final log = <String>[];
      final core = WorkspaceDaemonCore(
        sway: sway,
        env: env,
        log: log.add,
        applyInFlight: () => held,
      );
      await core.apply(ApplyReason.startup);
      expect(core.plan!.map[1], 'DP-4');

      // The app is walking the workspaces: workspace 1 lands on the laptop.
      held = true;
      expect(core.noteMove(1, 'eDP-1'), isFalse);
      expect(log.any((l) => l.contains('by hand')), isFalse);

      // The same move with nobody applying is the user's.
      held = false;
      expect(core.noteMove(1, 'eDP-1'), isTrue);
      expect(log.last, contains('workspace 1 was moved by hand to eDP-1, not DP-4'));
    });
  });

  group('KanshiController', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('kanshi_launcher_'));
    tearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    test('a launcher found at init reaches the config writer', () async {
      final config = ConfigService(
        configPath: '${tmp.path}/config',
        backupPrefix: '${tmp.path}/config.bak',
        writeOptions: KanshiWriteOptions.swayDefaults,
      );
      final mons = [_mon(id: 'eDP-1', x: 0), _mon(id: 'DP-1', x: 2560)];
      await config.saveProfiles([Profile(name: 'Talk', monitors: mons)]);
      final c = KanshiController(
        monitors: FakeMonitorService(
          supportsMirror: true,
          outputs: mons,
          writeOptions: KanshiWriteOptions.swayDefaults,
        ),
        config: config,
        mirrorRunner: FakeMirrorRunner(),
        processRunner: FakeProcessRunner(installed: {'kanshi-gui-mirror'}),
      );
      await c.init();
      final r = await c.setMirror('DP-1', 'eDP-1');
      expect(r.success, isTrue, reason: r.message);
      final lines = File('${tmp.path}/config').readAsLinesSync();
      expect(lines.any((l) => l.contains('exec kanshi-gui-mirror')), isTrue);
      expect(lines.any((l) => l.contains('exec wl-mirror')), isFalse,
          reason: 'the bare line is what started a duplicate per reload');
    });
  });
}
