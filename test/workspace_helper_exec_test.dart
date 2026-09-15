import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kanshi_gui/domain/workspace_plan.dart';
import 'package:kanshi_gui/models/monitor_tile_data.dart';
import 'package:kanshi_gui/models/profiles.dart';
import 'package:kanshi_gui/services/app_settings.dart';
import 'package:kanshi_gui/services/config_service.dart';
import 'package:kanshi_gui/services/kanshi_config_writer.dart';
import 'package:kanshi_gui/services/workspace_daemon.dart';
import 'package:kanshi_gui/services/workspace_daemon_core.dart';
import 'package:kanshi_gui/state/kanshi_controller.dart';

import 'fakes/fake_mirror_runner.dart';
import 'fakes/fake_monitor_service.dart';
import 'fakes/fake_process_runner.dart';
import 'fakes/fake_sway.dart';
import 'support/kanshi_exec.dart';

/// kanshi starting the workspace helper itself, once a profile is applied.
///
/// The property that matters most: a reload — which the app sends after every
/// save — must not rearrange anybody's desk. Only a change of screens may.
MonitorTileData _mon(String id, double x, {bool enabled = true}) =>
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
      enabled: enabled,
    );

List<MonitorTileData> desk() =>
    [_mon('DP-4', 0), _mon('DP-5', 2560), _mon('eDP-1', 5120)];

const _line = 'exec kanshi-gui-workspaced --from-kanshi';

int _helperLines(String config) =>
    config.split('\n').where((l) => l.trim() == _line).length;

void main() {
  final profiles = [
    Profile(name: 'Office', monitors: desk()),
    Profile(name: 'Laptop', monitors: [_mon('eDP-1', 0)]),
  ];
  const on = KanshiWriteOptions(
    injectSwayWorkspaceExec: true,
    useWorkspaceHelper: true,
  );

  group('started by kanshi', () {
    late FakeSway sway;
    late WorkspaceDaemonCore core;

    setUp(() {
      sway = FakeSway(
        live: desk(),
        // Everything still on the laptop: the plan disagrees.
        workspaces: {1: 'eDP-1', 2: 'eDP-1', 6: 'eDP-1'},
        focused: 6,
      );
      core = WorkspaceDaemonCore(
        sway: sway,
        env: FakeEnvironment(
          mode: WorkspaceManagementMode.interleaved,
          knownProfiles: [Profile(name: 'Office', monitors: desk())],
        ),
      );
    });
    tearDown(() => sway.dispose());

    test('after the screens changed it repairs and hands focus back',
        () async {
      await core.apply(ApplyReason.profileApplied, screensChanged: true);
      expect(sway.commands.single, contains('move workspace to output'));
      expect(sway.commands.single, endsWith('workspace number 6'));
    });

    test('after a reload on the same screens it only declares', () async {
      await core.apply(ApplyReason.profileApplied);
      expect(sway.commands.single, isNot(contains('move workspace to output')),
          reason: 'every save in the app ends in a kanshi reload');
      expect(sway.commands.single, contains('workspace 1 output'));
    });

    test('placement switched off still means silence', () async {
      final quiet = WorkspaceDaemonCore(
        sway: sway,
        env: FakeEnvironment(
          mode: WorkspaceManagementMode.off,
          knownProfiles: [Profile(name: 'Office', monitors: desk())],
        ),
      );
      await quiet.apply(ApplyReason.profileApplied, screensChanged: true);
      expect(sway.commands, isEmpty);
    });
  });

  group('telling a dock from a reload', () {
    test('the same screens in another order are the same desk', () {
      expect(outputFingerprint(desk()),
          outputFingerprint(desk().reversed.toList()));
    });

    test('a screen switched off is a change', () {
      final lidClosed = [
        _mon('DP-4', 0),
        _mon('DP-5', 2560),
        _mon('eDP-1', 5120, enabled: false),
      ];
      expect(outputFingerprint(lidClosed), isNot(outputFingerprint(desk())));
    });

    test('another screen on the same port is a change', () {
      final swapped = [
        _mon('DP-4', 0).copyWith(edidDescriptor: 'Other Screen 1'),
        _mon('DP-5', 2560),
        _mon('eDP-1', 5120),
      ];
      expect(outputFingerprint(swapped), isNot(outputFingerprint(desk())));
    });
  });

  group('the line in the config', () {
    test('once per profile, after its bindings', () {
      final out = KanshiConfigWriter.render(profiles, options: on);
      final lines = out.split('\n').map((l) => l.trim()).toList();
      expect(_helperLines(out), 2);
      final first = lines.indexOf(_line);
      expect(
        lines.sublist(0, first).lastWhere((l) => l.startsWith('exec ')),
        startsWith('exec swaymsg workspace '),
      );
    });

    test('not without the switch, and not without placement', () {
      expect(
        KanshiConfigWriter.render(profiles,
            options: const KanshiWriteOptions(injectSwayWorkspaceExec: true)),
        isNot(contains('kanshi-gui-workspaced')),
      );
      expect(
        KanshiConfigWriter.render(profiles,
            options: const KanshiWriteOptions(useWorkspaceHelper: true)),
        isNot(contains('kanshi-gui-workspaced')),
      );
    });

    test('kanshi hands it to the helper intact', () async {
      final tmp = Directory.systemTemp.createTempSync('helper_exec_');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final r = await runAsKanshiWould(_line,
          sandbox: tmp, stubs: const ['kanshi-gui-workspaced']);
      expect(r.failed, isFalse, reason: r.stderr);
      expect(r.invocations, [
        ['kanshi-gui-workspaced', '--from-kanshi'],
      ]);
    });
  });

  group('saving', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('helper_save_'));
    tearDown(() => tmp.deleteSync(recursive: true));

    ConfigService service(KanshiWriteOptions options) => ConfigService(
          configPath: '${tmp.path}/config',
          backupPrefix: '${tmp.path}/backups/config.bak',
          writeOptions: options,
        );

    test('repeated saves keep one line, and switching off removes it',
        () async {
      final cfg = service(on);
      await cfg.saveProfiles(profiles);
      await cfg.saveProfiles(profiles);
      final file = File(cfg.configPath);
      expect(_helperLines(file.readAsStringSync()), 2);
      expect(await cfg.workspaceHelperLineDisagrees(), isFalse);

      cfg.writeOptions = on.copyWith(useWorkspaceHelper: false);
      expect(await cfg.workspaceHelperLineDisagrees(), isTrue);
      await cfg.saveProfiles(profiles);
      expect(_helperLines(file.readAsStringSync()), 0);
      expect(await cfg.workspaceHelperLineDisagrees(), isFalse);

      cfg.writeOptions = on;
      expect(await cfg.workspaceHelperLineDisagrees(), isTrue);
    });

    test('an edit in place keeps the user\'s own lines and one helper line',
        () async {
      // A global output default is something the app cannot model, so the
      // save edits the file in place instead of rendering it whole.
      final file = File('${tmp.path}/config')
        ..writeAsStringSync('output "Make DP-4 SerialDP-4" scale 1\n\n');
      final cfg = service(on);
      await cfg.saveProfiles(profiles);
      final withMine = file.readAsStringSync().replaceFirst(
          "profile 'Office' {\n", "profile 'Office' {\n    exec notify-send docked\n");
      file.writeAsStringSync(withMine);
      await cfg.saveProfiles(profiles);
      await cfg.saveProfiles(profiles);
      final out = file.readAsStringSync();
      expect(out, contains('output "Make DP-4 SerialDP-4" scale 1'));
      expect(out, contains('exec notify-send docked'));
      expect(_helperLines(out), 2);
    });
  });

  group('the switch', () {
    late Directory tmp;
    late FakeProcessRunner runner;
    late WorkspaceDaemon daemon;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('helper_switch_');
      final unit = File('${tmp.path}/kanshi-gui-workspaces.service')
        ..writeAsStringSync('');
      runner = FakeProcessRunner(
        installed: {'systemctl', 'kanshi-gui-workspaced'},
        responses: {
          'systemctl --user is-enabled kanshi-gui-workspaces.service':
              ProcessResult(0, 0, 'enabled\n', ''),
        },
      );
      daemon = WorkspaceDaemon(runner: runner, searchPaths: [unit.path]);
    });
    tearDown(() => tmp.deleteSync(recursive: true));

    Future<KanshiController> controller({WorkspaceDaemon? workspaceDaemon}) async {
      final cfg = ConfigService(
        configPath: '${tmp.path}/config',
        backupPrefix: '${tmp.path}/backups/config.bak',
        writeOptions: KanshiWriteOptions.swayDefaults,
      );
      // Written before the switch was known, as by an older version.
      if (!File(cfg.configPath).existsSync()) {
        await cfg.saveProfiles([Profile(name: 'Office', monitors: desk())]);
      }
      final c = KanshiController(
        monitors: FakeMonitorService(
          outputs: desk(),
          writeOptions: KanshiWriteOptions.swayDefaults,
        ),
        config: cfg,
        mirrorRunner: FakeMirrorRunner(),
        processRunner: runner,
        workspaceDistribution: WorkspaceDistribution.interleaved,
        workspaceDaemon: workspaceDaemon,
      );
      await c.init();
      return c;
    }

    String config() => File('${tmp.path}/config').readAsStringSync();

    test('a config from before the switch gains the line on launch',
        () async {
      final c = await controller(workspaceDaemon: daemon);
      addTearDown(c.dispose);
      expect(_helperLines(config()), 1);
    });

    test('switching it off takes the line out', () async {
      final c = await controller(workspaceDaemon: daemon);
      addTearDown(c.dispose);
      runner.responses['systemctl --user is-enabled kanshi-gui-workspaces.service'] =
          ProcessResult(0, 1, 'disabled\n', '');
      await c.refreshWorkspaceHelper();
      expect(_helperLines(config()), 0);
    });

    test('a helper that is not installed gets no line', () async {
      runner.installed.remove('kanshi-gui-workspaced');
      final c = await controller(workspaceDaemon: daemon);
      addTearDown(c.dispose);
      expect(_helperLines(config()), 0);
    });

    test('without the switch handed in, systemd is never asked', () async {
      final c = await controller();
      addTearDown(c.dispose);
      expect(_helperLines(config()), 0);
      expect(runner.calls.where((call) => call.first == 'systemctl'), isEmpty);
    });
  });
}
