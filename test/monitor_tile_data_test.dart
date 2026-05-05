import 'package:flutter_test/flutter_test.dart';
import 'package:kanshi_gui/models/monitor_tile_data.dart';

MonitorTileData _mon({String? mirrorOf}) => MonitorTileData(
      id: 'A',
      manufacturer: 'A',
      x: 0,
      y: 0,
      width: 1920,
      height: 1080,
      rotation: 0,
      refresh: 60,
      resolution: '1920x1080',
      orientation: 'landscape',
      mirrorOf: mirrorOf,
    );

void main() {
  group('MonitorTileData.copyWith mirrorOf sentinel', () {
    // Nullable fields like mirrorOf need three distinguishable copyWith
    // operations: leave alone, set to a value, clear to null. With a plain
    // `String? mirrorOf` parameter the "leave alone" and "clear to null"
    // cases collapse — both look like null. The sentinel pattern in
    // monitor_tile_data.dart fixes that. These tests pin the contract so
    // a future refactor can't silently regress to the broken form.

    test('omitting mirrorOf preserves the existing value', () {
      final mirrored = _mon(mirrorOf: 'B');
      // Bumping x must not touch mirrorOf.
      final moved = mirrored.copyWith(x: 100);
      expect(moved.mirrorOf, equals('B'));
    });

    test('omitting mirrorOf preserves null when none was set', () {
      final unmirrored = _mon();
      final moved = unmirrored.copyWith(x: 100);
      expect(moved.mirrorOf, isNull);
    });

    test('explicitly passing null clears the mirror', () {
      final mirrored = _mon(mirrorOf: 'B');
      final cleared = mirrored.copyWith(mirrorOf: null);
      expect(cleared.mirrorOf, isNull);
    });

    test('explicit value overwrites prior value', () {
      final mirrored = _mon(mirrorOf: 'B');
      final retargeted = mirrored.copyWith(mirrorOf: 'C');
      expect(retargeted.mirrorOf, equals('C'));
    });
  });
}
