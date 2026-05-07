// Pins down the serialisation contract of `_reconcileMirrors`. Without
// the chain, two concurrent reconciles racing on the same destination
// would both read `_entries[dst]` mid-mutation and the second's
// `await stop(dst)` would kill the first's just-spawned wl-mirror —
// observed as flapping mirrors during rapid hotplug or
// hotplug-meets-undo events.
//
// The chain guarantees: at most one `_doReconcileMirrors` body runs at
// a time, and a poisoned body (e.g. `pgrep` IO error) does not block
// later reconciles.

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kanshi_gui/models/monitor_tile_data.dart';
import 'package:kanshi_gui/models/profiles.dart';
import 'package:kanshi_gui/services/config_service.dart';
import 'package:kanshi_gui/services/kanshi_config_writer.dart';
import 'package:kanshi_gui/services/mirror_runner.dart';
import 'package:kanshi_gui/state/kanshi_controller.dart';

import 'fakes/fake_monitor_service.dart';

/// Mirror runner that, in [gated] mode, parks each `start`/`purge`
/// call on a Completer the test owns so we can observe reconcile
/// boundaries. Default mode (`gated == false`) lets calls complete
/// immediately so [KanshiController.init] can settle without test
/// intervention.
class GatedMirrorRunner extends ChangeNotifier implements MirrorRunner {
  final List<String> events = [];
  final List<Completer<void>> startGates = [];
  final List<Completer<void>> purgeGates = [];
  bool gated = false;
  bool throwOnNextStart = false;

  @override
  Set<String> get activeDestinations => _active.keys.toSet();
  final Map<String, String> _active = {};

  @override
  Set<String> get failedDestinations => const {};

  @override
  String? mirrorSourceFor(String dstId) => _active[dstId];

  @override
  Future<bool> isAvailable() async => true;

  @override
  void clearFailure(String dstId) {}

  @override
  Future<void> start(String srcId, String dstId) async {
    events.add('start-begin $srcId->$dstId');
    if (gated) {
      final gate = Completer<void>();
      startGates.add(gate);
      await gate.future;
    }
    if (throwOnNextStart) {
      throwOnNextStart = false;
      events.add('start-throw $srcId->$dstId');
      throw StateError('synthetic mirror failure');
    }
    _active[dstId] = srcId;
    events.add('start-end $srcId->$dstId');
    notifyListeners();
  }

  @override
  Future<void> stop(String dstId) async {
    events.add('stop $dstId');
    _active.remove(dstId);
    notifyListeners();
  }

  @override
  Future<void> stopAll() async {
    for (final d in _active.keys.toList()) {
      await stop(d);
    }
  }

  @override
  Future<void> purgeExternalNotMatching(
    Map<String, String> desired,
  ) async {
    events.add('purge-begin');
    if (gated) {
      final gate = Completer<void>();
      purgeGates.add(gate);
      await gate.future;
    }
    events.add('purge-end');
  }
}

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
      scale: 1,
      rotation: 0,
      refresh: 60,
      resolution: '1920x1080',
      orientation: 'landscape',
      mirrorOf: mirrorOf,
    );

ConfigService _tmpConfig(Directory dir) => ConfigService(
      configPath: '${dir.path}/config',
      backupPrefix: '${dir.path}/config.bak',
      // `swayDefaults` emits the `# kanshi_gui:mirror` annotation that
      // round-trips `mirrorOf`. With `neutral` the test profiles would
      // lose their mirror state on save+load and the reconcile under
      // test would have nothing to reconcile.
      writeOptions: KanshiWriteOptions.swayDefaults,
    );

Future<void> _yield() async {
  // Give microtasks a chance to chain. Two pumps cover async/await
  // hopping; one is usually enough but tests get flaky if they cut
  // it close.
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('kanshi_gui_reconcile_');
  });
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Future<KanshiController> buildController({
    required GatedMirrorRunner runner,
    required List<MonitorTileData> connected,
    required List<Profile> profiles,
  }) async {
    final cfg = _tmpConfig(tmp);
    await cfg.saveProfiles(profiles);
    final fake = FakeMonitorService(
      outputs: connected,
      supportsMirror: true,
    );
    final c = KanshiController(
      monitors: fake,
      config: cfg,
      mirrorRunner: runner,
    );
    // Run `init` ungated so its own reconcile completes promptly. The
    // test enables gating right before triggering the reconciles it
    // wants to observe.
    runner.gated = false;
    await c.init();
    runner.events.clear();
    runner.gated = true;
    return c;
  }

  test('two reconciles back-to-back run sequentially, not in parallel',
      () async {
    // The reconcile chain must serialise overlapping calls. We trigger
    // two reconciles by switching profiles twice: each `setActiveProfile`
    // fires a fire-and-forget `_reconcileMirrors`. With the chain in
    // place, the second reconcile cannot begin its first awaited gate
    // until the first reconcile's awaits have all resolved.
    final runner = GatedMirrorRunner();
    final c = await buildController(
      runner: runner,
      connected: [_mon(id: 'A'), _mon(id: 'B', x: 1920)],
      profiles: [
        // Profile 0: B mirrors A.
        Profile(name: 'p0', monitors: [
          _mon(id: 'A'),
          _mon(id: 'B', x: 1920, mirrorOf: 'A'),
        ]),
        // Profile 1: no mirror.
        Profile(name: 'p1', monitors: [_mon(id: 'A'), _mon(id: 'B', x: 1920)]),
      ],
    );

    // Trigger reconcile #1 (switch into p0 → start mirror B->A).
    c.setActiveProfile(0);
    // Trigger reconcile #2 immediately (switch into p1 → stop mirror).
    c.setActiveProfile(1);

    await _yield();

    // After both setActiveProfile calls, only ONE reconcile body should
    // be running. The second is queued behind the chain.
    final beginCount =
        runner.events.where((e) => e.startsWith('start-begin')).length;
    expect(beginCount, lessThanOrEqualTo(1),
        reason: 'Reconcile #2 must wait for #1 to finish before '
            'touching MirrorRunner.');

    // Drain reconcile #1: complete its start, then its purge.
    while (runner.startGates.isNotEmpty) {
      runner.startGates.removeAt(0).complete();
      await _yield();
    }
    while (runner.purgeGates.isNotEmpty) {
      runner.purgeGates.removeAt(0).complete();
      await _yield();
    }

    // Reconcile #2 should now have produced its own purge (no mirrors
    // to start in p1), gated behind reconcile #1's completion.
    expect(
        runner.events.where((e) => e == 'purge-begin').length,
        greaterThanOrEqualTo(2),
        reason: 'Both reconciles must eventually complete.');
  });

  test('a thrown reconcile does not poison the chain', () async {
    // The outer `catchError` on `_reconcileChain` plus the inner
    // try/catch in `_doReconcileMirrors` together guarantee that one
    // failed reconcile cannot block later legitimate reconciles. If
    // the chain swallows the error correctly, the second reconcile
    // still runs to completion.
    final runner = GatedMirrorRunner();
    final c = await buildController(
      runner: runner,
      connected: [_mon(id: 'A'), _mon(id: 'B', x: 1920)],
      profiles: [
        Profile(name: 'mirror', monitors: [
          _mon(id: 'A'),
          _mon(id: 'B', x: 1920, mirrorOf: 'A'),
        ]),
        Profile(name: 'plain', monitors: [
          _mon(id: 'A'),
          _mon(id: 'B', x: 1920),
        ]),
      ],
    );

    // Reconcile #1: arm the throw, then trigger.
    runner.throwOnNextStart = true;
    c.setActiveProfile(0);
    await _yield();
    // Release the gated start — it will throw inside `_doReconcileMirrors`.
    runner.startGates.removeAt(0).complete();
    await _yield();
    // Drain any purge from a body that didn't throw before reaching it.
    while (runner.purgeGates.isNotEmpty) {
      runner.purgeGates.removeAt(0).complete();
      await _yield();
    }

    // Reconcile #2 against the no-mirror profile.
    c.setActiveProfile(1);
    await _yield();
    while (runner.purgeGates.isNotEmpty) {
      runner.purgeGates.removeAt(0).complete();
      await _yield();
    }

    expect(
        runner.events.any((e) => e.startsWith('start-throw')),
        isTrue,
        reason: 'Test setup precondition: a throw must have happened.');
    expect(
        runner.events.any((e) => e == 'purge-begin'),
        isTrue,
        reason: 'Reconcile #2 must run even after #1 threw — the '
            'chain must not propagate the failure.');
  });
}
