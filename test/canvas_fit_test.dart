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

  test('a switched-off screen is drawn inside the canvas', () {
    // This test used to assert the opposite: that a parked tile must not
    // affect the fit at all. The theory was that parked tiles live in the
    // margin the fit leaves — but the margin is a tenth of the viewport per
    // side, and a parked 1080p tile plus its gap is 2120 monitor-units wide,
    // so it only fits when the active cluster is over eight times that. In
    // practice it never was: switching a screen off pushed it off the canvas,
    // taking its "Enable display" menu with it and leaving no way back.
    //
    // Being drawn a little smaller is the price of being drawn at all.
    final layout = LayoutMath.computeDisplay(
      [_mon(id: 'A'), _mon(id: 'B', x: 1920), _mon(id: 'C', enabled: false)],
      viewport,
    );
    final parked = layout.displayMonitors.firstWhere((m) => m.id == 'C');
    expect(parked.x, greaterThanOrEqualTo(0));
    expect(parked.y, greaterThanOrEqualTo(0));
    expect(parked.x + parked.width, lessThanOrEqualTo(viewport.width),
        reason: 'the parked tile runs off the right edge');
    expect(parked.y + parked.height, lessThanOrEqualTo(viewport.height),
        reason: 'the parked tile runs off the bottom edge');
    expect(parked.width, greaterThan(20),
        reason: 'a sliver is not a screen the user can click');
  });

  test('the screens in use stay usable when one is switched off', () {
    // The concern behind the old assertion is still real — the arrangement
    // must not collapse to make room for a parked tile — so it is kept as a
    // bound rather than an equality.
    final withoutParked = LayoutMath.computeDisplay(
      [_mon(id: 'A'), _mon(id: 'B', x: 1920)],
      viewport,
    );
    final withParked = LayoutMath.computeDisplay(
      [_mon(id: 'A'), _mon(id: 'B', x: 1920), _mon(id: 'C', enabled: false)],
      viewport,
    );
    expect(withParked.scaleFactor,
        greaterThan(withoutParked.scaleFactor * 0.4),
        reason: 'one parked screen more than halved the active arrangement');
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

  test('every switched-off screen stays inside the canvas', () {
    // The case that matters most: "Only eDP-1" disables everything else in a
    // single click. If the parked lane leaves the canvas, the user has just
    // made their other screens both switched off AND unreachable.
    final layout = LayoutMath.computeDisplay(
      [
        _mon(id: 'A'),
        _mon(id: 'X', enabled: false),
        _mon(id: 'Y', enabled: false),
        _mon(id: 'Z', enabled: false),
      ],
      viewport,
    );
    expect(layout.displayMonitors, hasLength(4));
    for (final m in layout.displayMonitors) {
      expect(m.x, greaterThanOrEqualTo(0), reason: '${m.id} off the left');
      expect(m.y, greaterThanOrEqualTo(0), reason: '${m.id} off the top');
      expect(m.x + m.width, lessThanOrEqualTo(viewport.width),
          reason: '${m.id} off the right');
      expect(m.y + m.height, lessThanOrEqualTo(viewport.height),
          reason: '${m.id} off the bottom');
    }
  });

  test('a zero scale in the config does not blank the whole canvas', () {
    // `scale 0` is a plausible hand-edit in a file this app does not own.
    // Dividing by it made the bounding box infinite, drove the projection to
    // zero and rendered EVERY tile 0x0 — the 2.0.0 symptom, from one typo.
    final layout = LayoutMath.computeDisplay(
      [
        MonitorTileData(
          id: 'A',
          manufacturer: 'A',
          x: 0,
          y: 0,
          width: 1920,
          height: 1080,
          scale: 0,
          rotation: 0,
          refresh: 60,
          resolution: '1920x1080',
          orientation: 'landscape',
          enabled: true,
        ),
        _mon(id: 'B', x: 1920),
      ],
      viewport,
    );
    expect(layout.scaleFactor, greaterThan(0));
    for (final m in layout.displayMonitors) {
      expect(m.width, greaterThan(0), reason: '${m.id} rendered as nothing');
      expect(m.height, greaterThan(0));
    }
  });

  test('a zero-height viewport still yields drawable tiles', () {
    // Belt and braces for the shipped bug: if the canvas is ever handed no
    // height again, the tiles must overflow visibly rather than vanish.
    final layout = LayoutMath.computeDisplay(
      [_mon(id: 'A'), _mon(id: 'B', x: 1920)],
      const Size(1000, 0),
    );
    expect(layout.scaleFactor, greaterThan(0));
    for (final m in layout.displayMonitors) {
      expect(m.width, greaterThan(0));
      expect(m.height, greaterThan(0));
    }
  });
}
