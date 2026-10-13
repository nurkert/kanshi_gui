import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kanshi_gui/domain/lid_policy.dart';
import 'package:kanshi_gui/domain/workspace_plan.dart';
import 'package:kanshi_gui/models/monitor_tile_data.dart';
import 'package:kanshi_gui/models/profiles.dart';
import 'package:kanshi_gui/services/app_settings.dart';
import 'package:kanshi_gui/services/config_service.dart';
import 'package:kanshi_gui/services/kanshi_config_writer.dart';
import 'package:kanshi_gui/services/lid_switch.dart';
import 'package:kanshi_gui/services/sway_config_files.dart';
import 'package:kanshi_gui/state/drift_monitor.dart';
import 'package:kanshi_gui/state/kanshi_controller.dart';

import 'fakes/fake_mirror_runner.dart';
import 'fakes/fake_monitor_service.dart';
import 'fakes/fake_process_runner.dart';
import 'support/kanshi_exec.dart';

/// The laptop lid: the built-in screen goes off while the lid is closed and
/// another screen is on, and comes back when it opens.
MonitorTileData _mon(String id, double x, {bool enabled = true}) =>
    MonitorTileData(
      id: id,
      manufacturer: 'Panel $id',
      edidDescriptor: 'Make $id Serial$id',
      x: x,
      y: 0,
      width: 1920,
      height: 1080,
      rotation: 0,
      refresh: 60,
      resolution: '1920x1080',
      orientation: 'landscape',
      enabled: enabled,
    );

void main() {
  group('the rule', () {
    LidDecision decide(
      LidState lid,
      List<MonitorTileData> live, {
      LidTrigger trigger = LidTrigger.lidMoved,
      Set<String> switchedOff = const {},
      Set<String> mirrors = const {},
    }) =>
        decideLid(
          lid: lid,
          trigger: trigger,
          live: live,
          switchedOff: switchedOff,
          mirrorDestinations: mirrors,
        );

    test('closing it at a desk switches the panel off and remembers it', () {
      final d = decide(LidState.closed, [_mon('eDP-1', 0), _mon('DP-1', 1920)]);
      expect(d.switchOff, ['eDP-1']);
      expect(d.switchOn, isEmpty);
      expect(d.switchedOff, {'eDP-1'});
      expect(LidDecision.command('eDP-1', on: false), 'output eDP-1 disable');
    });

    test('closing it on the laptop alone never leaves the session dark', () {
      final d = decide(LidState.closed, [_mon('eDP-1', 0)]);
      expect(d.changesAnything, isFalse);
      expect(d.reason, contains('no other screen'));
    });

    test('a screen that switched off does not count as one to take over', () {
      final d = decide(LidState.closed,
          [_mon('eDP-1', 0), _mon('DP-1', 1920, enabled: false)]);
      expect(d.changesAnything, isFalse);
    });

    test('a projector mirroring the panel keeps the panel on', () {
      final d = decide(
        LidState.closed,
        [_mon('eDP-1', 0), _mon('HDMI-A-1', 1920)],
        mirrors: {'HDMI-A-1'},
      );
      expect(d.changesAnything, isFalse);
    });

    test('opening it brings back only what the lid switched off', () {
      final d = decide(
        LidState.open,
        [_mon('eDP-1', 0, enabled: false), _mon('DP-1', 1920)],
        switchedOff: {'eDP-1'},
      );
      expect(d.switchOn, ['eDP-1']);
      expect(d.switchedOff, isEmpty);
    });

    test('a panel the profile switched off stays off when the lid opens', () {
      final d = decide(
        LidState.open,
        [_mon('eDP-1', 0, enabled: false), _mon('DP-1', 1920)],
      );
      expect(d.changesAnything, isFalse);
    });

    test('kanshi switching the panel back on with the lid closed is undone',
        () {
      // A screen plugged in, or a save in the app: kanshi re-applies its
      // profile and the profile says the panel is on.
      final d = decide(
        LidState.closed,
        [_mon('eDP-1', 0), _mon('DP-1', 1920), _mon('DP-2', 3840)],
        trigger: LidTrigger.profileApplied,
        switchedOff: {'eDP-1'},
      );
      expect(d.switchOff, ['eDP-1']);
      expect(d.switchedOff, {'eDP-1'});
    });

    test('after kanshi applied a profile, nothing from before is remembered',
        () {
      // The new profile switched the panel off itself. Opening the lid later
      // must not switch it on against the profile.
      final closed = decide(
        LidState.closed,
        [_mon('eDP-1', 0, enabled: false), _mon('DP-1', 1920)],
        trigger: LidTrigger.profileApplied,
        switchedOff: {'eDP-1'},
      );
      expect(closed.changesAnything, isFalse);
      expect(closed.switchedOff, isEmpty);

      final open = decide(
        LidState.open,
        [_mon('eDP-1', 0, enabled: false), _mon('DP-1', 1920)],
        trigger: LidTrigger.profileApplied,
        switchedOff: {'eDP-1'},
      );
      expect(open.changesAnything, isFalse);
      expect(open.switchedOff, isEmpty);
    });

    test('an unknown lid changes nothing', () {
      final d = decide(LidState.unknown, [_mon('eDP-1', 0), _mon('DP-1', 1920)]);
      expect(d.changesAnything, isFalse);
    });

    test('a desktop has no panel to switch', () {
      final d = decide(LidState.closed, [_mon('DP-1', 0), _mon('DP-2', 1920)]);
      expect(d.changesAnything, isFalse);
    });

    test('built-in panels are recognised by connector, strictly', () {
      for (final yes in ['eDP-1', 'eDP-2', 'LVDS-1', 'DSI-1', 'eDP-1-1']) {
        expect(isBuiltInPanel(yes), isTrue, reason: yes);
      }
      // A name that matches goes into a sway command as is.
      for (final no in ['HDMI-A-1', 'DP-1', 'eDP', 'eDP-1; exec x', 'eDP-1 ']) {
        expect(isBuiltInPanel(no), isFalse, reason: no);
      }
    });

    test('the lid state reads the way ACPI and the binding write it', () {
      expect(LidState.fromAcpi('state:      closed\n'), LidState.closed);
      expect(LidState.fromAcpi('state:      open\n'), LidState.open);
      expect(LidState.fromAcpi(''), LidState.unknown);
      expect(LidState.fromArgument('closed'), LidState.closed);
      expect(LidState.fromArgument('--dry-run'), isNull);
    });
  });

  group('what the helper reads and remembers', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('lid_memory_'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test('remembered per sway session', () {
      LidMemory('/run/sway-1.sock', directory: tmp.path)
        ..switchedOff = {'eDP-1'}
        ..lid = LidState.closed
        ..write();
      final same = LidMemory('/run/sway-1.sock', directory: tmp.path).read();
      expect(same.switchedOff, {'eDP-1'});
      expect(same.lid, LidState.closed);
      // A new login is a new socket: last session's panel is not this one's.
      final next = LidMemory('/run/sway-2.sock', directory: tmp.path).read();
      expect(next.switchedOff, isEmpty);
      expect(next.lid, LidState.unknown);
    });

    test('ACPI wins over the remembered state, and is optional', () {
      final acpi = Directory('${tmp.path}/lid/LID0')
        ..createSync(recursive: true);
      File('${acpi.path}/state').writeAsStringSync('state:      closed\n');
      expect(
        readLidState(
            remembered: LidState.open, acpiDirectory: '${tmp.path}/lid'),
        LidState.closed,
      );
      expect(
        readLidState(
            remembered: LidState.open, acpiDirectory: '${tmp.path}/none'),
        LidState.open,
      );
    });
  });

  group('the sway binding', () {
    late Directory tmp;
    late File sway;
    late FakeProcessRunner runner;
    const original = 'set \$mod Mod4\n'
        'bindsym \$mod+Return exec foot\n';

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('lid_binding_');
      sway = File('${tmp.path}/config')..writeAsStringSync(original);
      runner = FakeProcessRunner();
    });
    tearDown(() => tmp.deleteSync(recursive: true));

    Future<LidSwitchScan> scan() async =>
        LidSwitchBinding.scan(await SwayConfigFiles.readLines(sway.path));

    test('added once, bound live, and taken out without a trace', () async {
      expect(await LidSwitchBinding.install(sway.path, runner: runner), isNull);
      expect(await LidSwitchBinding.install(sway.path, runner: runner), isNull);
      final text = sway.readAsStringSync();
      expect(text, startsWith(original));
      expect(text, contains(LidSwitchBinding.marker));
      for (final l in LidSwitchBinding.lines) {
        expect(text.split('\n').where((x) => x == l), hasLength(1));
      }
      expect((await scan()).installed, isTrue);
      // Bound in the running sway too, so it works before the next login.
      expect(runner.calls,
          anyElement(equals(['swaymsg', LidSwitchBinding.lines.first])));

      expect(
          await LidSwitchBinding.uninstall(sway.path, runner: runner), isNull);
      expect(sway.readAsStringSync(), original);
      expect(
        runner.calls,
        anyElement(
            equals(['swaymsg', 'unbindswitch --reload --locked lid:on'])),
      );
    });

    test("the user's own lid binding is named and never removed", () async {
      const own = 'bindswitch lid:on exec swaylock';
      sway.writeAsStringSync('$original$own\n');
      expect((await scan()).foreign.single.text, own);

      await LidSwitchBinding.install(sway.path, runner: runner);
      await LidSwitchBinding.uninstall(sway.path, runner: runner);
      expect(sway.readAsStringSync(), '$original$own\n');
    });

    test('found and removed in an included file, through a symlink', () async {
      final real = File('${tmp.path}/real-lid')
        ..writeAsStringSync('# mine\n\n${LidSwitchBinding.marker}\n'
            '${LidSwitchBinding.lines.join('\n')}\n# after\n');
      final link = Link('${tmp.path}/lid')..createSync(real.path);
      sway.writeAsStringSync('${original}include ${link.path}\n');
      expect((await scan()).installed, isTrue);

      await LidSwitchBinding.uninstall(sway.path, runner: runner);
      expect(real.readAsStringSync(), '# mine\n# after\n');
      expect(FileSystemEntity.isLinkSync(link.path), isTrue);
      expect(sway.readAsStringSync(), '${original}include ${link.path}\n');
    });
  });

  group('the kanshi line', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('lid_kanshi_'));
    tearDown(() => tmp.deleteSync(recursive: true));

    const lidLine = 'exec ${KanshiWriteOptions.lidHelperCommand}';
    const helperLine = 'exec ${KanshiWriteOptions.workspaceHelperCommand}';
    final profiles = [
      Profile(name: 'Desk', monitors: [_mon('eDP-1', 0), _mon('DP-1', 1920)]),
      Profile(name: 'Laptop', monitors: [_mon('eDP-1', 0)]),
    ];
    int count(String text, String line) =>
        text.split('\n').where((l) => l.trim() == line).length;

    ConfigService service(KanshiWriteOptions o) => ConfigService(
          configPath: '${tmp.path}/config',
          backupPrefix: '${tmp.path}/backups/config.bak',
          writeOptions: o,
        );

    test('in every profile while on, gone when off', () async {
      final cfg = service(KanshiWriteOptions.swayDefaults
          .copyWith(injectSwayWorkspaceExec: false, useLidHelper: true));
      await cfg.saveProfiles(profiles);
      final file = File(cfg.configPath);
      expect(count(file.readAsStringSync(), lidLine), 2);
      expect(await cfg.lidHelperLineDisagrees(), isFalse);

      cfg.writeOptions = cfg.writeOptions.copyWith(useLidHelper: false);
      expect(await cfg.lidHelperLineDisagrees(), isTrue);
      await cfg.saveProfiles(profiles);
      expect(count(file.readAsStringSync(), lidLine), 0);
      expect(await cfg.lidHelperLineDisagrees(), isFalse);
    });

    test('left out where the workspace helper line runs, which does the lid',
        () async {
      final cfg = service(KanshiWriteOptions.swayDefaults
          .copyWith(useWorkspaceHelper: true, useLidHelper: true));
      await cfg.saveProfiles(profiles);
      final text = File(cfg.configPath).readAsStringSync();
      expect(count(text, lidLine), 0);
      expect(count(text, helperLine), 2);
      expect(await cfg.lidHelperLineDisagrees(), isFalse);
    });

    test('runs as one plain command through kanshi and /bin/sh', () async {
      final r = await runAsKanshiWould(lidLine,
          sandbox: tmp, stubs: const ['kanshi-gui-workspaced']);
      expect(r.invocations, [
        ['kanshi-gui-workspaced', '--lid'],
      ]);
    });
  });

  group('a panel switched off by the lid', () {
    final desk = Profile(
      name: 'Desk',
      monitors: [_mon('eDP-1', 0), _mon('DP-1', 1920)],
    );
    final live = [_mon('eDP-1', 0, enabled: false), _mon('DP-1', 1920)];

    test('gets no workspaces', () {
      final plan = planWorkspaces(
        profiles: [desk],
        live: live,
        distribution: WorkspaceManagementMode.interleaved.distribution,
      );
      expect(plan, isNotNull);
      expect(plan!.map.values.toSet(), {'DP-1'});
    });

    test('is not reported as moved', () {
      final drift = DriftMonitor();
      drift.recompute(isLive: true, activeProfile: desk, liveOutputs: live);
      expect(drift.issues, isEmpty);
    });
  });

  group('the switch in the app', () {
    late Directory tmp;
    late File sway;
    late FakeMonitorService monitors;
    late KanshiController c;
    late AppSettings settings;

    setUp(() async {
      tmp = Directory.systemTemp.createTempSync('lid_controller_');
      sway = File('${tmp.path}/sway/config')
        ..createSync(recursive: true)
        ..writeAsStringSync('set \$mod Mod4\n');
      final runner = FakeProcessRunner(
        installed: {LidSwitchBinding.helper},
        responses: {
          'swaymsg -t get_version': ProcessResult(
              0, 0, '{"loaded_config_file_name":"${sway.path}"}', ''),
        },
      );
      monitors = FakeMonitorService(
        writeOptions: KanshiWriteOptions.swayDefaults,
        outputs: [_mon('eDP-1', 0), _mon('DP-1', 1920)],
      );
      c = KanshiController(
        monitors: monitors,
        config: ConfigService(
          configPath: '${tmp.path}/kanshi/config',
          backupPrefix: '${tmp.path}/backups/config.bak',
          writeOptions: monitors.writeOptions,
        ),
        mirrorRunner: FakeMirrorRunner(),
        processRunner: runner,
      );
      settings = AppSettings(filePath: '${tmp.path}/settings.json');
      c.applyStartupSettings(settings);
      await c.init();
    });

    tearDown(() {
      c.dispose();
      tmp.deleteSync(recursive: true);
    });

    test('offered on a laptop with the helper, and off until asked', () {
      expect(c.supportsLidSwitch, isTrue);
      expect(c.lidSwitchOn, isFalse);
      expect(File(c.config.configPath).existsSync() &&
              File(c.config.configPath)
                  .readAsStringSync()
                  .contains('--lid'),
          isFalse);
    });

    test('switching on writes all three places, switching off undoes them',
        () async {
      final facts = await c.lidSwitchFacts();
      expect(facts.canChange, isTrue);
      expect(facts.swayConfigPath, sway.path);

      final on = await c.setLidSwitch(true, swayConfigPath: sway.path);
      expect(on.success, isTrue, reason: on.message);
      expect(c.lidSwitchOn, isTrue);
      expect(sway.readAsStringSync(), contains(LidSwitchBinding.lines.first));
      expect((await AppSettings.load(path: settings.filePath)).lidTurnsOffPanel,
          isTrue);
      expect(File(c.config.configPath).readAsStringSync(),
          contains('exec ${KanshiWriteOptions.lidHelperCommand}'));
      // Reloaded, so kanshi runs the line now — with the lid closed already,
      // the panel goes off without waiting for the lid to move.
      expect(monitors.calls, contains('restart'));

      final off = await c.setLidSwitch(false, swayConfigPath: sway.path);
      expect(off.success, isTrue, reason: off.message);
      expect(sway.readAsStringSync(), 'set \$mod Mod4\n');
      expect((await AppSettings.load(path: settings.filePath)).lidTurnsOffPanel,
          isFalse);
      expect(File(c.config.configPath).readAsStringSync(), isNot(contains('--lid')));
    });

    test('a desktop is not asked about a lid', () async {
      monitors.outputs = [_mon('DP-1', 0), _mon('DP-2', 1920)];
      await c.refreshConnectedMonitors();
      expect(c.supportsLidSwitch, isFalse);
    });
  });
}
