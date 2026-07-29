import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kanshi_gui/widgets/monitor_tile.dart';

/// The corner grip changes the output's SCALE, which is uniform. The tile
/// therefore has to keep its aspect ratio while it is dragged, or the
/// rectangle stops representing the monitor's actual shape halfway through
/// the gesture — a 16:9 screen could be dragged into a square while the scale
/// it committed described something else entirely.
void main() {
  const tile = Size(480, 270); // 16:9

  double aspect(Size s) => s.width / s.height;

  test('dragging outward grows the tile without changing its shape', () {
    final next = resizeByGrip(tile, const Offset(60, 4));
    expect(next.width, greaterThan(tile.width));
    expect(aspect(next), closeTo(aspect(tile), 1e-9));
  });

  test('dragging inward shrinks it, also without changing its shape', () {
    final next = resizeByGrip(tile, const Offset(-40, -10));
    expect(next.width, lessThan(tile.width));
    expect(aspect(next), closeTo(aspect(tile), 1e-9));
  });

  test('movement across the diagonal expresses nothing, so nothing happens',
      () {
    // Perpendicular to the tile's diagonal: a shape change, which a uniform
    // scale cannot represent.
    final perpendicular = Offset(tile.height, -tile.width);
    final next = resizeByGrip(tile, perpendicular / 10);
    expect(next.width, closeTo(tile.width, 1e-9));
    expect(next.height, closeTo(tile.height, 1e-9));
  });

  test('movement along the diagonal tracks the cursor', () {
    // Half a diagonal outward should be about half again as large.
    final along = Offset(tile.width, tile.height) / 2;
    final next = resizeByGrip(tile, along);
    expect(next.width, closeTo(tile.width * 1.5, 0.5));
  });

  test('the aspect ratio survives the minimum-size clamp', () {
    // Collapsing all the way in used to floor width and height separately,
    // which is a shape change at exactly the moment the tile is smallest and
    // the distortion most obvious.
    final next = resizeByGrip(tile, const Offset(-10000, -10000));
    expect(next.width, greaterThanOrEqualTo(20));
    expect(next.height, greaterThanOrEqualTo(20));
    expect(aspect(next), closeTo(aspect(tile), 1e-6));
  });

  test('a degenerate tile is left alone rather than dividing by zero', () {
    expect(resizeByGrip(Size.zero, const Offset(10, 10)), Size.zero);
  });
}
