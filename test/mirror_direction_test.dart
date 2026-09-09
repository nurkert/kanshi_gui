// Which screen shows which — and where the copy is put.
//
// From a presentation that went wrong: the laptop was dragged onto the
// television tile, the dialog read "Mirror eDP-1 onto DP-1?", and what that
// did was make the LAPTOP the copy. Every workspace went to the television,
// the laptop showed the television shrunk to fit, and the pointer could
// wander onto the copy. These tests pin the direction the app chooses on its
// own and the geometry the copy is applied at.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kanshi_gui/domain/mirror_geometry.dart';
import 'package:kanshi_gui/models/monitor_tile_data.dart';
import 'package:kanshi_gui/models/profiles.dart';
import 'package:kanshi_gui/services/config_service.dart';
import 'package:kanshi_gui/services/kanshi_config_writer.dart';
import 'package:kanshi_gui/state/kanshi_controller.dart';

import 'fakes/fake_mirror_runner.dart';
import 'fakes/fake_monitor_service.dart';
import 'support/kanshi_exec.dart';

MonitorTileData _mon({
  required String id,
  double x = 0,
  double y = 0,
  String? mirrorOf,
}) =>
    MonitorTileData(
      id: id,
      manufacturer: id,
      x: x,
      y: y,
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
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('kanshi_gui_mirror_dir_');
  });
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  ConfigService cfg({KanshiWriteOptions? options}) => ConfigService(
        configPath: '${tmp.path}/config',
        backupPrefix: '${tmp.path}/config.bak',
        writeOptions: options ?? KanshiWriteOptions.neutral,
      );

  group('KanshiController', () {
    // Television on the left, laptop on the right: leftmost is NOT the
    // built-in panel, so the two rules disagree and the test can tell them
    // apart.
    final tv = _mon(id: 'DP-1', x: 0);
    final laptop = _mon(id: 'eDP-1', x: 1920);

    test('mirrorAll makes every other screen show the built-in panel',
        () async {
      final config = cfg();
      await config.saveProfiles([
        Profile(name: 'Talk', monitors: [tv, laptop]),
      ]);
      final fake = FakeMonitorService(
        supportsMirror: true,
        outputs: [tv, laptop],
      );
      final c = KanshiController(
        monitors: fake,
        config: config,
        mirrorRunner: FakeMirrorRunner(),
      );
      await c.init();

      final r = await c.mirrorAll();
      expect(r.success, isTrue, reason: r.message);
      final after = {for (final m in c.activeMonitors) m.id: m};
      expect(after['DP-1']!.mirrorOf, 'eDP-1');
      expect(after['eDP-1']!.mirrorOf, isNull);
    });

    test('a copy is applied a pointer gap away from the screens it copies',
        () async {
      final config = cfg();
      await config.saveProfiles([
        Profile(name: 'Talk', monitors: [tv, laptop]),
      ]);
      final fake = FakeMonitorService(
        supportsMirror: true,
        outputs: [tv, laptop],
      );
      final c = KanshiController(
        monitors: fake,
        config: config,
        mirrorRunner: FakeMirrorRunner(),
      );
      await c.init();
      await c.mirrorAll();

      final appliedTv = fake.applied.lastWhere((m) => m.id == 'DP-1');
      // The laptop's logical rectangle ends at 3840; the copy starts a
      // full gap to the right of that, so the pointer cannot reach it.
      expect(appliedTv.x, 3840 + MirrorGeometry.pointerGap);
      expect(appliedTv.y, 0);
      // The model still remembers where the television really was.
      expect(c.activeMonitors.firstWhere((m) => m.id == 'DP-1').x, 0);
    });

    test('releasing a copy that was read back detached rejoins the others',
        () async {
      // As if the app had been restarted with the mirror in the config: the
      // parser hands the detached position to the model.
      final farTv = tv.copyWith(
        x: 3840 + MirrorGeometry.pointerGap,
        mirrorOf: 'eDP-1',
      );
      final config = cfg();
      await config.saveProfiles([
        Profile(name: 'Talk', monitors: [farTv, laptop]),
      ]);
      final fake = FakeMonitorService(
        supportsMirror: true,
        outputs: [farTv, laptop],
      );
      final c = KanshiController(
        monitors: fake,
        config: config,
        mirrorRunner: FakeMirrorRunner(),
      );
      await c.init();

      final r = await c.setMirror('DP-1', null);
      expect(r.success, isTrue, reason: r.message);
      final released = c.activeMonitors.firstWhere((m) => m.id == 'DP-1');
      expect(released.mirrorOf, isNull);
      expect(released.x, 3840, reason: 'flush against the laptop');
    });

    test('the messages say what shows what', () async {
      final config = cfg();
      await config.saveProfiles([
        Profile(name: 'Talk', monitors: [tv, laptop]),
      ]);
      final fake = FakeMonitorService(
        supportsMirror: true,
        outputs: [tv, laptop],
      );
      final c = KanshiController(
        monitors: fake,
        config: config,
        mirrorRunner: FakeMirrorRunner(),
      );
      await c.init();
      expect((await c.setMirror('DP-1', 'eDP-1')).message,
          'DP-1 now shows eDP-1.');
      expect((await c.setMirror('DP-1', null)).message,
          'DP-1 is its own screen again.');
    });
  });

  group('KanshiConfigWriter', () {
    test('the copy is written a pointer gap away, the source where it was',
        () async {
      final config = cfg(options: KanshiWriteOptions.swayDefaults);
      await config.saveProfiles([
        Profile(name: 'Talk', monitors: [
          _mon(id: 'eDP-1', x: 0),
          _mon(id: 'DP-1', x: 1920, mirrorOf: 'eDP-1'),
        ]),
      ]);
      final text = File('${tmp.path}/config').readAsStringSync();
      expect(text, contains("output 'eDP-1' enable"));
      expect(
        RegExp(r"output 'DP-1' enable .* position (\d+),(\d+)")
            .firstMatch(text)!
            .group(1),
        '${1920 + MirrorGeometry.pointerGap.toInt()}',
      );
      expect(
        RegExp(r"output 'eDP-1' enable .* position (\d+),")
            .firstMatch(text)!
            .group(1),
        '0',
      );
    });

    test('with the launcher installed the exec line goes through it',
        () async {
      final config = cfg(
        options: KanshiWriteOptions.swayDefaults.copyWith(
          useMirrorLauncher: true,
          mirrorScaling: 'cover',
        ),
      );
      await config.saveProfiles([
        Profile(name: 'Talk', monitors: [
          _mon(id: 'eDP-1', x: 0),
          _mon(id: 'DP-1', x: 1920, mirrorOf: 'eDP-1'),
        ]),
      ]);
      final lines = File('${tmp.path}/config').readAsLinesSync();
      final exec = lines.singleWhere((l) => l.contains('kanshi-gui-mirror'));
      expect(lines.any((l) => l.contains('exec wl-mirror')), isFalse);

      // Run the line the way kanshi would, and look at what arrives.
      final r = await runAsKanshiWould(
        exec,
        sandbox: tmp,
        stubs: const ['kanshi-gui-mirror'],
      );
      expect(r.failed, isFalse, reason: r.stderr);
      expect(r.invocations, [
        ['kanshi-gui-mirror', 'DP-1', 'eDP-1', 'cover'],
      ]);
    });

    test('without the launcher the line still calls wl-mirror directly',
        () async {
      final config = cfg(options: KanshiWriteOptions.swayDefaults);
      await config.saveProfiles([
        Profile(name: 'Talk', monitors: [
          _mon(id: 'eDP-1', x: 0),
          _mon(id: 'DP-1', x: 1920, mirrorOf: 'eDP-1'),
        ]),
      ]);
      final lines = File('${tmp.path}/config').readAsLinesSync();
      expect(
        lines.singleWhere((l) => l.contains('exec wl-mirror')).trim(),
        'exec wl-mirror --scaling fit --fullscreen-output "DP-1" "eDP-1"',
      );
    });
  });

  group('kanshi-gui-mirror', () {
    // The real script, through a real shell, with stubs standing in for
    // pgrep and wl-mirror.
    final script = File('bin/kanshi-gui-mirror');

    Future<KanshiExecResult> run(String line, {required bool running}) {
      final bin = Directory('${tmp.path}/bin')..createSync(recursive: true);
      File('${bin.path}/kanshi-gui-mirror')
        ..writeAsStringSync(script.readAsStringSync())
        ..setLastModifiedSync(DateTime.now());
      Process.runSync('chmod', ['755', '${bin.path}/kanshi-gui-mirror']);
      // pgrep says "found" with exit 0 and "nothing" with exit 1.
      File('${bin.path}/pgrep')
          .writeAsStringSync('#!/bin/sh\nexit ${running ? 0 : 1}\n');
      Process.runSync('chmod', ['755', '${bin.path}/pgrep']);
      return runAsKanshiWould(line, sandbox: tmp, stubs: const ['wl-mirror']);
    }

    test('starts wl-mirror when nothing targets the destination', () async {
      final r = await run(
        'exec kanshi-gui-mirror "DP-1" "eDP-1" fit',
        running: false,
      );
      expect(r.failed, isFalse, reason: r.stderr);
      expect(r.invocations, [
        ['wl-mirror', '--scaling', 'fit', '--fullscreen-output', 'DP-1', 'eDP-1'],
      ]);
    });

    test('starts nothing when one already does', () async {
      final r = await run(
        'exec kanshi-gui-mirror "DP-1" "eDP-1" fit',
        running: true,
      );
      expect(r.failed, isFalse, reason: r.stderr);
      expect(r.invocations, isEmpty);
    });
  });
}
