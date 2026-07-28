import 'package:flutter_test/flutter_test.dart';
import 'package:kanshi_gui/models/monitor_tile_data.dart';
import 'package:kanshi_gui/models/profiles.dart';
import 'package:kanshi_gui/state/drift_monitor.dart';

MonitorTileData _mon({
  required String id,
  double x = 0,
  double y = 0,
  bool enabled = true,
  String? mirrorOf,
}) =>
    MonitorTileData(
      id: id,
      manufacturer: id,
      x: x,
      y: y,
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
  DriftMonitor withState({
    required List<MonitorTileData> profile,
    required List<MonitorTileData> live,
    bool isLive = true,
  }) {
    final d = DriftMonitor();
    d.recompute(
      isLive: isLive,
      activeProfile: Profile(name: 'Desk', monitors: profile),
      liveOutputs: live,
    );
    return d;
  }

  test('a matching layout is not drift', () {
    final d = withState(
      profile: [_mon(id: 'A'), _mon(id: 'B', x: 1920)],
      live: [_mon(id: 'A'), _mon(id: 'B', x: 1920)],
    );
    expect(d.issues, isEmpty);
    expect(d.shouldSurface, isFalse);
  });

  test('rounding noise is absorbed', () {
    // A fractional scale rarely divides a mode into whole numbers, so an
    // exact comparison would report drift permanently.
    final d = withState(
      profile: [_mon(id: 'A', x: 1920)],
      live: [_mon(id: 'A', x: 1921)],
    );
    expect(d.issues, isEmpty);
  });

  test('a real displacement is reported with both positions', () {
    final d = withState(
      profile: [_mon(id: 'A', x: 1920)],
      live: [_mon(id: 'A', x: 6560)],
    );
    expect(d.issues, hasLength(1));
    expect(d.issues.single, contains('1920'));
    expect(d.issues.single, contains('6560'));
  });

  test('a disabled output has no position to drift', () {
    final d = withState(
      profile: [_mon(id: 'A', x: 1920, enabled: false)],
      live: [_mon(id: 'A', x: 0)],
    );
    expect(d.issues, isEmpty);
  });

  test('a mirror destination inherits its geometry, so it never drifts', () {
    // Its stored coordinates are advisory while the mirror is active;
    // comparing them would light the banner up permanently.
    final d = withState(
      profile: [_mon(id: 'A'), _mon(id: 'B', x: 1920, mirrorOf: 'A')],
      live: [_mon(id: 'A'), _mon(id: 'B', x: 0)],
    );
    expect(d.issues, isEmpty);
  });

  test('an unplugged output is not drift either', () {
    final d = withState(
      profile: [_mon(id: 'A'), _mon(id: 'B', x: 1920)],
      live: [_mon(id: 'A')],
    );
    expect(d.issues, isEmpty);
  });

  test('an offline backend reports nothing', () {
    final d = withState(
      profile: [_mon(id: 'A', x: 1920)],
      live: [_mon(id: 'A', x: 0)],
      isLive: false,
    );
    expect(d.issues, isEmpty);
  });

  group('dismissal', () {
    test('hides the current round without pretending it went away', () {
      final d = withState(
        profile: [_mon(id: 'A', x: 1920)],
        live: [_mon(id: 'A', x: 6560)],
      );
      expect(d.shouldSurface, isTrue);
      d.dismiss();
      expect(d.shouldSurface, isFalse);
      expect(d.issues, isNotEmpty,
          reason: 'dismiss hides the banner, it does not resolve the drift');
    });

    test('a fresh hotplug lets a new difference through again', () {
      final d = withState(
        profile: [_mon(id: 'A', x: 1920)],
        live: [_mon(id: 'A', x: 6560)],
      );
      d.dismiss();
      d.resetDismissal();
      expect(d.shouldSurface, isTrue);
    });
  });

  test('recompute reports whether anything changed', () {
    final d = DriftMonitor();
    final profile = Profile(name: 'Desk', monitors: [_mon(id: 'A', x: 1920)]);
    expect(
      d.recompute(
          isLive: true,
          activeProfile: profile,
          liveOutputs: [_mon(id: 'A', x: 6560)]),
      isTrue,
    );
    // Same inputs again: no repaint warranted.
    expect(
      d.recompute(
          isLive: true,
          activeProfile: profile,
          liveOutputs: [_mon(id: 'A', x: 6560)]),
      isFalse,
    );
  });
}
