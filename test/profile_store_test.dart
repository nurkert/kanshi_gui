import 'package:flutter_test/flutter_test.dart';
import 'package:kanshi_gui/models/monitor_tile_data.dart';
import 'package:kanshi_gui/models/profiles.dart';
import 'package:kanshi_gui/state/profile_store.dart';

MonitorTileData _mon({required String id, double x = 0}) => MonitorTileData(
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

Profile _p(String name, [List<MonitorTileData>? mons]) =>
    Profile(name: name, monitors: mons ?? [_mon(id: 'A')]);

void main() {
  test('the exposed list cannot be mutated', () {
    // The whole point: no caller may hold a mutable list, because that is how
    // a safety-net revert ended up writing into an orphan while the
    // compositor and the config drifted apart.
    final s = ProfileStore()..replaceAll([_p('A')]);
    expect(() => s.profiles.add(_p('B')), throwsUnsupportedError);
    expect(() => s.profiles[0] = _p('B'), throwsUnsupportedError);
  });

  test('replaceAll copies, so the caller keeps their own list', () {
    final mine = [_p('A')];
    final s = ProfileStore()..replaceAll(mine);
    mine.single.name = 'renamed afterwards';
    mine.single.monitors[0] = _mon(id: 'Z');
    expect(s.profiles.single.name, 'A');
    expect(s.profiles.single.monitors.single.id, 'A');
  });

  group('removeAt keeps the active pointer meaningful', () {
    test('deleting the active setup leaves nothing active', () {
      // Quietly moving the user into a neighbour they did not choose would
      // be a surprise.
      final s = ProfileStore()..replaceAll([_p('A'), _p('B')], activeIndex: 1);
      s.removeAt(1);
      expect(s.activeIndex, isNull);
    });

    test('deleting before the active one shifts the index down', () {
      final s = ProfileStore()..replaceAll([_p('A'), _p('B')], activeIndex: 1);
      s.removeAt(0);
      expect(s.activeIndex, 0);
      expect(s.active!.name, 'B', reason: 'still the same setup');
    });

    test('deleting after the active one leaves it alone', () {
      final s = ProfileStore()..replaceAll([_p('A'), _p('B')], activeIndex: 0);
      s.removeAt(1);
      expect(s.activeIndex, 0);
    });
  });

  test('an out-of-range active index is not accepted', () {
    final s = ProfileStore()..replaceAll([_p('A')], activeIndex: 7);
    expect(s.activeIndex, isNull);
    s.activeIndex = -1;
    expect(s.activeIndex, isNull);
  });

  group('updateMonitorIn', () {
    test('resolves the profile and the output at call time', () {
      final s = ProfileStore()
        ..replaceAll([_p('Desk', [_mon(id: 'A'), _mon(id: 'B', x: 1920)])]);
      expect(
        s.updateMonitorIn('Desk', 'B', (m) => m.copyWith(x: 4000)),
        isTrue,
      );
      expect(s.profiles.single.monitors[1].x, 4000);
    });

    test('reports failure when the profile is gone', () {
      // A revert may fire after the user deleted the setup it belonged to.
      // Silently doing nothing would leave the compositor and the config
      // disagreeing with no one the wiser.
      final s = ProfileStore()..replaceAll([_p('Desk')]);
      expect(s.updateMonitorIn('Gone', 'A', (m) => m), isFalse);
      expect(s.updateMonitorIn('Desk', 'Z', (m) => m), isFalse);
    });

    test('writes into the named profile, not the active one', () {
      final s = ProfileStore()
        ..replaceAll([_p('Desk'), _p('Other')], activeIndex: 1);
      s.updateMonitorIn('Desk', 'A', (m) => m.copyWith(x: 512));
      expect(s.profiles[0].monitors.single.x, 512);
      expect(s.profiles[1].monitors.single.x, 0);
    });
  });

  test('updateActiveMonitor is a no-op when nothing is active', () {
    final s = ProfileStore()..replaceAll([_p('Desk')]);
    expect(s.updateActiveMonitor('A', (m) => m.copyWith(x: 1)), isFalse);
  });

  test('nameTaken ignores the profile being renamed', () {
    final s = ProfileStore()..replaceAll([_p('Desk'), _p('Office')]);
    expect(s.nameTaken('office'), isTrue);
    expect(s.nameTaken('Office', excludingIndex: 1), isFalse);
  });
}
