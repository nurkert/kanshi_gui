// "Just open it": the mirror as a window the user opened, not a state the app
// keeps up. Nothing saved, nothing restarted, nothing the cleanup may kill.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kanshi_gui/models/monitor_tile_data.dart';
import 'package:kanshi_gui/models/profiles.dart';
import 'package:kanshi_gui/services/app_settings.dart';
import 'package:kanshi_gui/services/config_service.dart';
import 'package:kanshi_gui/services/kanshi_config_writer.dart';
import 'package:kanshi_gui/services/mirror_runner.dart';
import 'package:kanshi_gui/state/kanshi_controller.dart';

import 'fakes/fake_mirror_runner.dart';
import 'fakes/fake_monitor_service.dart';
import 'fakes/fake_process_runner.dart';

MonitorTileData _mon(String id, double x) => MonitorTileData(
      id: id,
      manufacturer: id,
      x: x,
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
  setUp(() => tmp = Directory.systemTemp.createTempSync('kanshi_gui_mw_'));
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Future<(KanshiController, FakeProcessRunner, FakeMirrorRunner)> boot({
    required bool fullscreen,
  }) async {
    final config = ConfigService(
      configPath: '${tmp.path}/config',
      backupPrefix: '${tmp.path}/config.bak',
      writeOptions: KanshiWriteOptions.neutral,
    );
    final tv = _mon('DP-1', 0);
    final laptop = _mon('eDP-1', 1920);
    await config.saveProfiles([Profile(name: 'Talk', monitors: [tv, laptop])]);
    final runner = FakeProcessRunner();
    final mirrors = FakeMirrorRunner();
    final c = KanshiController(
      monitors: FakeMonitorService(supportsMirror: true, outputs: [tv, laptop]),
      config: config,
      mirrorRunner: mirrors,
      processRunner: runner,
    );
    c.applyStartupSettings(AppSettings(
      filePath: '${tmp.path}/settings.json',
      mirrorMode: MirrorMode.window,
      mirrorFullscreen: fullscreen,
    ));
    await c.init();
    return (c, runner, mirrors);
  }

  List<String>? launch(FakeProcessRunner r) => r.calls
      .where((c) => c.first == 'sh' && c.join(' ').contains('setsid wl-mirror'))
      .lastOrNull;

  test('opens wl-mirror fullscreen on the destination and saves nothing',
      () async {
    final (c, runner, mirrors) = await boot(fullscreen: true);
    final before = await File('${tmp.path}/config').readAsString();

    final r = await c.setMirror('DP-1', 'eDP-1');
    expect(r.success, isTrue, reason: r.message);

    final call = launch(runner)!;
    expect(call.sublist(call.length - 3), ['--fullscreen-output', 'DP-1', 'eDP-1']);
    expect(call, containsAllInOrder(['--title', MirrorRunner.windowTitle]));
    expect(c.activeMonitors.every((m) => m.mirrorOf == null), isTrue,
        reason: 'the setup does not learn about it');
    expect(mirrors.activeDestinations, isEmpty,
        reason: 'the app does not keep it up');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(await File('${tmp.path}/config').readAsString(), before);
  });

  test('without fullscreen it focuses the destination and opens a window',
      () async {
    final (c, runner, _) = await boot(fullscreen: false);
    await c.setMirror('DP-1', 'eDP-1');

    final call = launch(runner)!;
    expect(call, isNot(contains('--fullscreen-output')));
    expect(call.last, 'eDP-1');
    final focus = runner.calls.indexWhere(
        (c) => c.join(' ') == 'swaymsg focus output DP-1');
    expect(focus, isNonNegative);
    expect(focus, lessThan(runner.calls.indexOf(call)));
  });

  test('the cleanup never takes such a window for a stray', () {
    final running = MirrorRunner.parsePgrepForTest(
      '100 wl-mirror --scaling fit --title ${MirrorRunner.windowTitle} '
      '--fullscreen-output DP-1 eDP-1\n'
      '200 wl-mirror --scaling fit --fullscreen-output DP-2 eDP-1\n',
    );
    expect(running.map((p) => p.pid), [200]);
  });

  test('the setting survives a restart', () async {
    final path = '${tmp.path}/s.json';
    await AppSettings(
      filePath: path,
      mirrorMode: MirrorMode.window,
      mirrorFullscreen: false,
    ).save();
    final s = await AppSettings.load(path: path);
    expect(s.mirrorMode, MirrorMode.window);
    expect(s.mirrorFullscreen, isFalse);
    final fresh = await AppSettings.load(path: '${tmp.path}/none.json');
    expect(fresh.mirrorMode, MirrorMode.managed);
    expect(fresh.mirrorFullscreen, isTrue);
  });
}
