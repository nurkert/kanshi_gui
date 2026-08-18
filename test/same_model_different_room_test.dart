import 'package:flutter_test/flutter_test.dart';
import 'package:kanshi_gui/domain/output_matcher.dart';
import 'package:kanshi_gui/models/monitor_tile_data.dart';

/// Two rooms, two docks, four Samsung panels of one model — and a saved setup
/// that got re-pointed at the wrong room.
///
/// The user had a three-screen office saved, recorded down to the EDID serials
/// of its two Samsungs. In a different room they plugged into a different dock
/// holding two panels of the same model — different units, different serials —
/// and that dock handed out the same connector names, DP-4 and DP-5.
///
/// The descriptors disagreed. The old [OutputMatcher.strength] fell through to
/// the connector pass anyway, the names agreed, and the app called them the
/// same screens: it applied the other room's positions here (which is what the
/// dashed drift ghosts on the canvas were), and re-hydration then overwrote
/// the saved serials with these panels'. The setup for the other room was
/// gone, and could never match those screens again.
MonitorTileData _screen({
  required String connector,
  required String descriptor,
  double x = 0,
}) =>
    MonitorTileData(
      id: connector,
      manufacturer: descriptor,
      edidDescriptor: descriptor,
      x: x,
      y: 0,
      width: 2560,
      height: 1440,
      scale: 1.0,
      rotation: 0,
      refresh: 60,
      resolution: '2560x1440',
      orientation: 'landscape',
      enabled: true,
    );

// The other room. Still standing there, exactly as it was.
final _savedLeft = _screen(
    connector: 'DP-4', descriptor: 'Samsung Electric Company LS27D60xU HK2XA00042');
final _savedRight = _screen(
    connector: 'DP-5',
    descriptor: 'Samsung Electric Company LS27D60xU HK2XA00043',
    x: 2560);

// This room. Same model, same ports, different hardware.
final _hereLeft = _screen(
    connector: 'DP-4', descriptor: 'Samsung Electric Company LS27D60xU HK2XA01318');
final _hereRight = _screen(
    connector: 'DP-5',
    descriptor: 'Samsung Electric Company LS27D60xU HK2XA01167',
    x: 2560);

final _panel = _screen(
    connector: 'eDP-1',
    descriptor: 'InfoVision Optoelectronics (Kunshan) Co.,Ltd China 0x057D Unknown',
    x: 5120);

void main() {
  group('a recorded EDID outranks a connector name', () {
    test('two panels of one model on the same port are not the same screen',
        () {
      expect(OutputMatcher.strength(_hereLeft, _savedLeft), isNull,
          reason: 'DP-4 in both rooms, and two different displays');
      expect(OutputMatcher.strength(_hereRight, _savedRight), isNull);
    });

    test('and the saved setup no longer claims this room', () {
      final pairs = OutputMatcher.pair(
        [_savedLeft, _savedRight, _panel],
        [_hereLeft, _hereRight, _panel],
      );
      expect(pairs.length, 1,
          reason: 'only the laptop panel is genuinely the same screen');
      expect(pairs[2], 2);
    });

    test('the same screen on a different port is still the same screen', () {
      // The other half of the bargain, and the reason descriptors are recorded
      // at all: a dock that renumbers the ports must not lose the setup.
      final movedPort = _screen(
          connector: 'DP-1',
          descriptor: 'Samsung Electric Company LS27D60xU HK2XA01318');
      expect(OutputMatcher.strength(movedPort, _hereLeft),
          MatchStrength.descriptor);
    });

    test('an entry that never recorded a descriptor still matches by port', () {
      // The migration path for configs written before descriptors existed.
      final legacy = MonitorTileData(
        id: 'DP-4',
        manufacturer: '',
        edidDescriptor: '',
        x: 0,
        y: 0,
        width: 2560,
        height: 1440,
        scale: 1.0,
        rotation: 0,
        refresh: 60,
        resolution: '2560x1440',
        orientation: 'landscape',
        enabled: true,
      );
      expect(OutputMatcher.strength(_hereLeft, legacy),
          MatchStrength.connector);
    });

    test('a serial that appears later is the same screen, weakly', () {
      // A descriptor is `make model serial`, and the composer writes the word
      // Unknown where the display reported none. Two that agree on make and
      // model and differ only in that a serial turned up — firmware update,
      // different cable, a compositor reading EDID more thoroughly — are one
      // display introducing itself properly, not two displays. Refusing
      // outright would drop the setup it belongs to.
      final wasUnknown = _screen(
          connector: 'DP-4', descriptor: 'Samsung Electric Company LS27D60xU Unknown');
      expect(OutputMatcher.strength(_hereLeft, wasUnknown), MatchStrength.label,
          reason: 'without the serial it is exactly as strong as the label');
    });

    test('but two real serials are still proof of two screens', () {
      expect(OutputMatcher.strength(_hereLeft, _savedLeft), isNull);
    });

    test('and a different model with an unknown serial is still not it', () {
      final other = _screen(
          connector: 'DP-4', descriptor: 'Samsung Electric Company LS24X999 Unknown');
      expect(OutputMatcher.strength(_hereLeft, other), isNull);
    });

    test('the stronger claim still wins when both are on offer', () {
      // The panel that knows its serial must not be handed to the entry that
      // only half-matches, when the entry it really belongs to is right there.
      final wasUnknown = _screen(
          connector: 'DP-9',
          descriptor: 'Samsung Electric Company LS27D60xU Unknown');
      final exact = _screen(
          connector: 'DP-9',
          descriptor: 'Samsung Electric Company LS27D60xU HK2XA01318');
      final pairs = OutputMatcher.pair([wasUnknown, exact], [_hereLeft]);
      expect(pairs, {1: 0});
    });

    test('a live output with no EDID at all still matches by port', () {
      // An adapter or a KVM that strips EDID. The saved side knows who it is;
      // the live side offers nothing, so the port is all there is.
      final blind = _screen(connector: 'DP-4', descriptor: '');
      expect(OutputMatcher.strength(blind, _savedLeft),
          MatchStrength.connector);
    });
  });
}
