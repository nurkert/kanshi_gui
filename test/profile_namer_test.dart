import 'package:flutter_test/flutter_test.dart';
import 'package:kanshi_gui/models/monitor_tile_data.dart';
import 'package:kanshi_gui/services/profile_namer.dart';

MonitorTileData _mon(String id) => MonitorTileData(
      id: id,
      manufacturer: id,
      x: 0,
      y: 0,
      width: 1920,
      height: 1080,
      rotation: 0,
      refresh: 60,
      resolution: '1920x1080',
      orientation: 'landscape',
    );

void main() {
  test('single embedded panel → Laptop only', () {
    expect(ProfileNamer.suggest([_mon('eDP-1')]), equals('Laptop only'));
  });

  test('single external display → Single display', () {
    expect(ProfileNamer.suggest([_mon('DP-1')]), equals('Single display'));
  });

  test('embedded + one external → Docked', () {
    expect(
      ProfileNamer.suggest([_mon('eDP-1'), _mon('DP-1')]),
      equals('Docked'),
    );
  });

  test('embedded + two externals → Docked + 2 externals', () {
    expect(
      ProfileNamer.suggest([_mon('eDP-1'), _mon('DP-1'), _mon('HDMI-A-1')]),
      equals('Docked + 2 externals'),
    );
  });

  test('two externals, no laptop → Dual external', () {
    expect(
      ProfileNamer.suggest([_mon('DP-1'), _mon('DP-2')]),
      equals('Dual external'),
    );
  });

  test('three externals → Triple Setup', () {
    expect(
      ProfileNamer.suggest([_mon('DP-1'), _mon('DP-2'), _mon('DP-3')]),
      equals('Triple Setup'),
    );
  });

  test('empty list → Empty', () {
    expect(ProfileNamer.suggest([]), equals('Empty'));
  });
}
