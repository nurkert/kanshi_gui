import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kanshi_gui/models/monitor_tile_data.dart';
import 'package:kanshi_gui/models/profiles.dart';
import 'package:kanshi_gui/services/config_service.dart';
import 'package:kanshi_gui/services/kanshi_autostart.dart';
import 'package:kanshi_gui/services/kanshi_config_writer.dart';
import 'package:kanshi_gui/services/process_runner.dart';
import 'package:kanshi_gui/state/kanshi_controller.dart';

import 'fakes/fake_mirror_runner.dart';
import 'fakes/fake_monitor_service.dart';
import 'fakes/fake_process_runner.dart';

/// kanshi is not running for the first look and running for every look after
/// something has started it.
class _StartsKanshi extends FakeProcessRunner {
  _StartsKanshi({super.responses, super.installed});

  bool started = false;

  @override
  Future<ProcessResult> run(
    String executable,
    List<String> arguments, {
    Duration timeout = ProcessRunner.defaultTimeout,
  }) async {
    if (executable == 'pgrep') {
      calls.add([executable, ...arguments]);
      return ProcessResult(0, started ? 0 : 1, '', '');
    }
    final r = await super.run(executable, arguments, timeout: timeout);
    if (executable == 'bash' && arguments.last.contains('setsid kanshi')) {
      started = true;
    }
    return r;
  }
}

MonitorTileData _mon(String id) => MonitorTileData(
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
    );

void main() {
  late Directory tmp;
  late File swayConfig;
  late _StartsKanshi runner;
  late KanshiController c;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('kanshi_setup_ctl_');
    swayConfig = File('${tmp.path}/sway/config')
      ..createSync(recursive: true)
      ..writeAsStringSync('set \$mod Mod4\n');
    // The sway config is named by "sway" itself, so nothing in this test can
    // reach the real one on the machine running it.
    runner = _StartsKanshi(
      installed: {'kanshi', 'kanshictl'},
      responses: {
        'swaymsg -t get_version': ProcessResult(0, 0,
            '{"loaded_config_file_name":"${swayConfig.path}"}', ''),
      },
    );
    final cfg = ConfigService(
      configPath: '${tmp.path}/kanshi/config',
      backupPrefix: '${tmp.path}/backups/config.bak',
      writeOptions: KanshiWriteOptions.neutral,
    );
    await cfg.saveProfiles([
      Profile(name: 'Desk', monitors: [_mon('eDP-1')]),
    ]);
    c = KanshiController(
      monitors: FakeMonitorService(writeOptions: KanshiWriteOptions.swayDefaults),
      config: cfg,
      mirrorRunner: FakeMirrorRunner(),
      processRunner: runner,
    );
  });

  tearDown(() {
    c.dispose();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('the facts name the lines, with the config kanshi has to be told',
      () async {
    final facts = await c.kanshiSetupFacts();
    expect(facts.installed, isTrue);
    expect(facts.configExists, isTrue);
    expect(facts.autostart.found, isFalse);
    expect(facts.autostart.swayConfigPath, swayConfig.path);
    expect(facts.swayConfigWritable, isTrue);
    expect(facts.swayLines, [
      'exec kanshi -c ${tmp.path}/kanshi/config',
      'exec_always kanshictl reload',
    ]);
  });

  test('adding writes the lines once and starts kanshi', () async {
    final facts = await c.kanshiSetupFacts();
    final r = await c.addKanshiToSwayConfig(facts);
    expect(r.success, isTrue, reason: r.message);
    expect(swayConfig.readAsStringSync(),
        contains('${KanshiAutostart.marker}\nexec kanshi -c'));
    expect(runner.calls.where((call) => call.first == 'bash'), hasLength(1));
    expect(c.kanshiRunning, isTrue);

    // A second go — a stale dialog, a double click — adds nothing.
    final before = swayConfig.readAsStringSync();
    final again = await c.addKanshiToSwayConfig(facts);
    expect(again.success, isTrue);
    expect(swayConfig.readAsStringSync(), before);
  });

  test('a sway config it cannot write is refused before anything happens',
      () async {
    final facts = await c.kanshiSetupFacts();
    final readOnly = KanshiSetupFacts(
      installed: facts.installed,
      configExists: facts.configExists,
      autostart: facts.autostart,
      swayLines: facts.swayLines,
    );
    final r = await c.addKanshiToSwayConfig(readOnly);
    expect(r.success, isFalse);
    expect(swayConfig.readAsStringSync(), 'set \$mod Mod4\n');
    expect(runner.calls.where((call) => call.first == 'bash'), isEmpty);
  });
}
