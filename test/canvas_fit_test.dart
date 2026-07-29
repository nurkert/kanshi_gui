import 'dart:ui' show Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:kanshi_gui/models/monitor_tile_data.dart';
import 'package:kanshi_gui/services/layout_math.dart';

MonitorTileData _mon({
  required String id,
  double x = 0,
  bool enabled = true,
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
    );

void main() {
  const viewport = Size(1000, 700);

  test('a disabled screen does not shrink the ones in use', () {
    // Parked tiles are shown beside the arrangement, but they used to count
    // towards the bounding box the fit is computed from — so switching a
    // screen off made every remaining screen smaller, to make room for
    // something the user cannot interact with.
    final withoutParked = LayoutMath.computeDisplay(
      [_mon(id: 'A'), _mon(id: 'B', x: 1920)],
      viewport,
    );
    final withParked = LayoutMath.computeDisplay(
      [_mon(id: 'A'), _mon(id: 'B', x: 1920), _mon(id: 'C', enabled: false)],
      viewport,
    );
    expect(withParked.scaleFactor, closeTo(withoutParked.scaleFactor, 1e-9));
  });

  test('the parked tile is still laid out', () {
    final layout = LayoutMath.computeDisplay(
      [_mon(id: 'A'), _mon(id: 'C', enabled: false)],
      viewport,
    );
    expect(layout.displayMonitors.map((m) => m.id), containsAll(['A', 'C']));
  });

  test('everything disabled still produces a usable fit', () {
    // The fallback: with no active cluster to fit to, the parked tiles are
    // all there is, and the canvas must not divide by an empty bounding box.
    final layout = LayoutMath.computeDisplay(
      [_mon(id: 'A', enabled: false), _mon(id: 'B', x: 1920, enabled: false)],
      viewport,
    );
    expect(layout.scaleFactor, greaterThan(0));
    expect(layout.displayMonitors, hasLength(2));
  });

  test('more disabled screens do not compound the shrinking', () {
    final one = LayoutMath.computeDisplay(
      [_mon(id: 'A'), _mon(id: 'X', enabled: false)],
      viewport,
    );
    final many = LayoutMath.computeDisplay(
      [
        _mon(id: 'A'),
        _mon(id: 'X', enabled: false),
        _mon(id: 'Y', enabled: false),
        _mon(id: 'Z', enabled: false),
      ],
      viewport,
    );
    expect(many.scaleFactor, closeTo(one.scaleFactor, 1e-9));
  });
}
