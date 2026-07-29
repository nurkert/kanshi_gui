import 'package:flutter_test/flutter_test.dart';
import 'package:kanshi_gui/models/monitor_tile_data.dart';
import 'package:kanshi_gui/state/mirror_coordinator.dart';

import 'fakes/fake_mirror_runner.dart';
import 'fakes/fake_monitor_service.dart';

MonitorTileData _mon({
  required String id,
  bool enabled = true,
  String? mirrorOf,
  double x = 0,
}) =>
    MonitorTileData(
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
      enabled: enabled,
      mirrorOf: mirrorOf,
    );

void main() {
  group('desiredMirrors', () {
    test('needs both endpoints physically present', () {
      // Spinning up wl-mirror for an absent endpoint just makes it exit,
      // burn the retry budget and mark the destination failed.
      final profile = [
        _mon(id: 'A'),
        _mon(id: 'B', mirrorOf: 'A'),
        _mon(id: 'C', mirrorOf: 'GONE'),
      ];
      expect(
        MirrorCoordinator.desiredMirrors(profile, {'A', 'B', 'C'}),
        {'B': 'A'},
      );
      expect(
        MirrorCoordinator.desiredMirrors(profile, {'A'}),
        isEmpty,
        reason: 'the destination itself is not connected',
      );
    });

    test('a disabled destination mirrors nothing', () {
      final profile = [_mon(id: 'A'), _mon(id: 'B', mirrorOf: 'A', enabled: false)];
      expect(MirrorCoordinator.desiredMirrors(profile, {'A', 'B'}), isEmpty);
    });
  });

  group('evacuationTargets', () {
    test('offers the other independent outputs, resolved and live', () {
      final profile = [
        _mon(id: 'A'),
        _mon(id: 'B', mirrorOf: 'A'),
        _mon(id: 'C', x: 1920),
        _mon(id: 'D', enabled: false),
      ];
      final targets = MirrorCoordinator.evacuationTargets(
        destination: 'B',
        profileMonitors: profile,
        connectedIds: {'A', 'B', 'C', 'D'},
        resolveConnector: (id) => id,
      );
      expect(targets, ['A', 'C']);
      expect(targets, isNot(contains('B')), reason: 'not onto itself');
      expect(targets, isNot(contains('D')), reason: 'not onto a disabled one');
    });

    test('drops targets the compositor does not know', () {
      final targets = MirrorCoordinator.evacuationTargets(
        destination: 'B',
        profileMonitors: [_mon(id: 'A'), _mon(id: 'B', mirrorOf: 'A')],
        connectedIds: {'B'},
        resolveConnector: (id) => id,
      );
      expect(targets, isEmpty);
    });
  });

  group('reconcile', () {
    Future<(FakeMonitorService, FakeMirrorRunner)> run(
      List<MonitorTileData> profile, {
      List<String> live = const ['A', 'B'],
      bool supportsMirror = true,
      bool evacuate = true,
    }) async {
      final svc = FakeMonitorService(supportsMirror: supportsMirror);
      final runner = FakeMirrorRunner();
      await MirrorCoordinator(svc, runner).reconcile(
        supportsMirror: supportsMirror,
        profileMonitors: profile,
        liveOutputs: [for (final id in live) _mon(id: id)],
        resolveConnector: (id) => id,
        evacuate: evacuate,
      );
      return (svc, runner);
    }

    test('starts the mirror the setup asks for', () async {
      final (_, runner) =
          await run([_mon(id: 'A'), _mon(id: 'B', mirrorOf: 'A')]);
      expect(runner.activeDestinations, contains('B'));
    });

    test('evacuates the destination before spawning', () async {
      // Otherwise any workspace already on the destination ends up buried
      // under wl-mirror's fullscreen layer and is unreachable.
      final (svc, _) =
          await run([_mon(id: 'A'), _mon(id: 'B', mirrorOf: 'A')]);
      expect(svc.calls.where((c) => c.startsWith('evacuate')), isNotEmpty);
    });

    test('skips evacuation when the caller already did it', () async {
      final (svc, _) = await run(
        [_mon(id: 'A'), _mon(id: 'B', mirrorOf: 'A')],
        evacuate: false,
      );
      expect(svc.calls.where((c) => c.startsWith('evacuate')), isEmpty);
    });

    test('stops everything on a backend that cannot mirror', () async {
      final (_, runner) = await run(
        [_mon(id: 'A'), _mon(id: 'B', mirrorOf: 'A')],
        supportsMirror: false,
      );
      expect(runner.activeDestinations, isEmpty);
    });

    test('concurrent reconciles are serialised', () async {
      // Without the chain, a hotplug-driven reconcile racing a
      // profile-switch reconcile can kill a process the other just spawned.
      final svc = FakeMonitorService(supportsMirror: true);
      final runner = FakeMirrorRunner();
      final c = MirrorCoordinator(svc, runner);
      final profile = [_mon(id: 'A'), _mon(id: 'B', mirrorOf: 'A')];
      await Future.wait([
        for (var i = 0; i < 5; i++)
          c.reconcile(
            supportsMirror: true,
            profileMonitors: profile,
            liveOutputs: [_mon(id: 'A'), _mon(id: 'B')],
            resolveConnector: (id) => id,
          ),
      ]);
      expect(runner.activeDestinations, {'B'});
    });
  });
}
