import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kanshi_gui/models/monitor_tile_data.dart';
import 'package:kanshi_gui/services/layout_math.dart';
import 'package:kanshi_gui/widgets/drift_ghost_painter.dart';

MonitorTileData _mon({required String id, double x = 0, double scale = 1}) =>
    MonitorTileData(
      id: id,
      manufacturer: id,
      x: x,
      y: 0,
      width: 1920,
      height: 1080,
      scale: scale,
      rotation: 0,
      refresh: 60,
      resolution: '1920x1080',
      orientation: 'landscape',
    );

const _layout = DisplayLayout(
  scaleFactor: 0.25,
  offsetX: 10,
  offsetY: 20,
  originX: 0,
  originY: 0,
  displayMonitors: [],
);

void main() {
  test('nothing to draw means no repaint work', () {
    const a = DriftGhostPainter(
        drifted: [], layout: _layout, color: Color(0xFFE8A33D));
    const b = DriftGhostPainter(
        drifted: [], layout: _layout, color: Color(0xFFE8A33D));
    expect(a.shouldRepaint(b), isFalse);
  });

  test('a moved screen forces a repaint', () {
    final a = DriftGhostPainter(
        drifted: [_mon(id: 'A', x: 0)],
        layout: _layout,
        color: const Color(0xFFE8A33D));
    final b = DriftGhostPainter(
        drifted: [_mon(id: 'A', x: 6560)],
        layout: _layout,
        color: const Color(0xFFE8A33D));
    expect(a.shouldRepaint(b), isTrue);
  });

  test('a changed canvas fit forces a repaint', () {
    // Otherwise the ghosts stay where they were while the tiles reflow, and
    // the picture claims a drift that is not there.
    final a = DriftGhostPainter(
        drifted: [_mon(id: 'A')],
        layout: _layout,
        color: const Color(0xFFE8A33D));
    final b = DriftGhostPainter(
      drifted: [_mon(id: 'A')],
      layout: const DisplayLayout(
        scaleFactor: 0.5,
        offsetX: 10,
        offsetY: 20,
        originX: 0,
        originY: 0,
        displayMonitors: [],
      ),
      color: const Color(0xFFE8A33D),
    );
    expect(a.shouldRepaint(b), isTrue);
  });

  testWidgets('it paints without throwing, including at fractional scale',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: CustomPaint(
          size: const Size(800, 600),
          painter: DriftGhostPainter(
            drifted: [
              _mon(id: 'A', x: 6560),
              _mon(id: 'B', x: 9000, scale: 1.25),
            ],
            layout: _layout,
            color: const Color(0xFFE8A33D),
          ),
        ),
      ),
    ));
    expect(tester.takeException(), isNull);
  });
}
