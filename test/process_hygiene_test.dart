import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kanshi_gui/models/monitor_tile_data.dart';
import 'package:kanshi_gui/services/backends/sway_backend.dart';
import 'package:kanshi_gui/services/config_service.dart';
import 'package:kanshi_gui/services/kanshi_config_writer.dart';
import 'package:kanshi_gui/state/kanshi_controller.dart';

import 'fakes/fake_mirror_runner.dart';
import 'fakes/fake_monitor_service.dart';
import 'fakes/fake_process_runner.dart';

/// What the app leaves behind when it goes away.
///
/// The hotplug watcher is a `swaymsg -t subscribe` SUBPROCESS, and Dart does
/// not take its children with it when the isolate ends. Closing the window
/// therefore orphaned one every single launch. It was invisible for two
/// reasons: an orphan dies by itself at the next output event (its stdout
/// pipe is gone, so the write fails), and the stream controller does kill it
/// — in `onCancel`, which fires when a *listener* goes away and not when the
/// process simply exits.
///
/// Found by counting processes on a machine that had been running the app on
/// and off for two hours: two strays, an hour and a half old, on a desk whose
/// screens had not changed all morning.
void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('kanshi_hygiene_'));
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('the sway backend', () {
    SwayBackend backend(FakeProcessRunner runner) =>
        SwayBackend(runner: runner);

    test('shutdown reaps the hotplug watcher', () async {
      final runner = FakeProcessRunner(installed: {'swaymsg'});
      final b = backend(runner);
      final sub = b.watchOutputs().listen((_) {});
      addTearDown(sub.cancel);
      // The subscribe subprocess is started asynchronously inside
      // watchOutputs; let it get going.
      await Future<void>.delayed(Duration.zero);
      expect(
        runner.calls.any((c) => c.contains('subscribe')),
        isTrue,
        reason: 'the watcher never started, so this proves nothing',
      );

      await b.shutdown();

      // The fake drops a controller when its process is killed, so a live
      // one is exactly the leak this is about.
      expect(runner.isStreamOpen('swaymsg -t subscribe -m ["output"]'), isFalse,
          reason: 'the subscribe subprocess outlived the app');
    });

    test('shutdown is safe when nothing was ever watched', () async {
      await backend(FakeProcessRunner(installed: {'swaymsg'})).shutdown();
    });

    test('cancelling the stream still reaps it, and shutdown does not '
        'then kill it twice', () async {
      final runner = FakeProcessRunner(installed: {'swaymsg'});
      final b = backend(runner);
      final sub = b.watchOutputs().listen((_) {});
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();
      await b.shutdown();
      expect(runner.isStreamOpen('swaymsg -t subscribe -m ["output"]'),
          isFalse);
    });
  });

  group('the controller', () {
    test('shutdown reaches the backend and disposes', () async {
      final fake = FakeMonitorService(
        outputs: [
          MonitorTileData(
            id: 'DP-1',
            manufacturer: 'Panel',
            edidDescriptor: 'Make DP-1 Serial1',
            x: 0,
            y: 0,
            width: 2560,
            height: 1440,
            scale: 1.0,
            rotation: 0,
            refresh: 60,
            resolution: '2560x1440',
            orientation: 'landscape',
            enabled: true,
          ),
        ],
        writeOptions: KanshiWriteOptions.swayDefaults,
      );
      final c = KanshiController(
        monitors: fake,
        config: ConfigService(
          configPath: '${tmp.path}/config',
          backupPrefix: '${tmp.path}/backups/config.bak',
          writeOptions: KanshiWriteOptions.swayDefaults,
        ),
        mirrorRunner: FakeMirrorRunner(),
      );
      await c.init();
      expect(fake.shutdownCalls, 0);

      await c.shutdown();

      expect(fake.shutdownCalls, 1);
      // Idempotent: the exit hook can fire alongside an ordinary dispose.
      c.dispose();
      await c.shutdown();
      expect(fake.shutdownCalls, 2);
    });
  });
}
