import 'package:flutter_test/flutter_test.dart';
import 'package:kanshi_gui/domain/output_matcher.dart';
import 'package:kanshi_gui/models/monitor_tile_data.dart';

MonitorTileData _mon({
  required String id,
  String? label,
  String descriptor = '',
}) =>
    MonitorTileData(
      id: id,
      manufacturer: label ?? id,
      edidDescriptor: descriptor,
      x: 0,
      y: 0,
      width: 1920,
      height: 1080,
      rotation: 0,
      refresh: 60,
      resolution: '1920x1080',
      orientation: 'landscape',
    );

const _samsung = 'Samsung Electric Company S34J55x H4LR500240';
const _twinA = 'Acme Twin Unknown';

void main() {
  group('normalize', () {
    test('collapses the untidiness that comes out of real EDID', () {
      // Doubled spaces and trailing blanks are common in EDID strings, and
      // tools disagree on case for connector names. Comparing raw strings
      // loses matches for reasons that have nothing to do with the hardware.
      expect(OutputMatcher.normalize('  Foo   Bar  '), 'foo bar');
      expect(OutputMatcher.same('DP-1', 'dp-1'), isTrue);
      expect(OutputMatcher.same('Foo  Bar', 'foo bar'), isTrue);
      expect(OutputMatcher.same('DP-1', 'DP-2'), isFalse);
    });
  });

  group('strength', () {
    test('the EDID descriptor outranks the connector name', () {
      final live = _mon(id: 'DP-3', descriptor: _samsung, label: _samsung);
      final entry = _mon(id: 'DP-1', descriptor: _samsung, label: _samsung);
      expect(OutputMatcher.strength(live, entry), MatchStrength.descriptor);
    });

    test('the connector matches when no descriptor was ever recorded', () {
      expect(
        OutputMatcher.strength(_mon(id: 'DP-1'), _mon(id: 'DP-1')),
        MatchStrength.connector,
      );
    });

    test('the display label is the last resort', () {
      final live = _mon(id: 'DP-9', label: 'Dell U2720Q');
      final entry = _mon(id: 'DP-1', label: 'Dell U2720Q');
      expect(OutputMatcher.strength(live, entry), MatchStrength.label);
    });

    test('unrelated screens do not match', () {
      expect(
        OutputMatcher.strength(
            _mon(id: 'DP-1', label: 'A'), _mon(id: 'HDMI-A-1', label: 'B')),
        isNull,
      );
    });
  });

  group('resolveConnector', () {
    final live = [
      _mon(id: 'DP-3', descriptor: _samsung, label: _samsung),
      _mon(id: 'eDP-1', label: 'Built-in'),
    ];

    test('finds the current port from a stable descriptor', () {
      expect(OutputMatcher.resolveConnector(_samsung, live), 'DP-3');
    });

    test('passes an unknown reference straight through', () {
      // So a compositor call fails with a comprehensible message rather than
      // an empty argument.
      expect(OutputMatcher.resolveConnector('DP-99', live), 'DP-99');
    });
  });

  group('pair', () {
    test('a stronger signal is never outbid by a weaker one', () {
      // The reboot case: the ultrawide moved from DP-1 to DP-3, and some
      // other screen has taken over DP-1. Matching on the connector name
      // first would hand the ultrawide's profile entry to the wrong display.
      final entries = [
        _mon(id: 'DP-1', descriptor: _samsung, label: _samsung),
      ];
      final live = [
        _mon(id: 'DP-1', label: 'Some Other Screen'),
        _mon(id: 'DP-3', descriptor: _samsung, label: _samsung),
      ];
      expect(OutputMatcher.pair(entries, live), {0: 1});
    });

    test('two identical panels do not collapse onto one live output', () {
      // Without the claim set, a profile holding two indistinguishable
      // monitors re-hydrates both from whichever live output comes first and
      // the two physical screens silently swap mode lists.
      final entries = [
        _mon(id: 'DP-1', descriptor: _twinA, label: 'Acme Twin'),
        _mon(id: 'DP-2', descriptor: _twinA, label: 'Acme Twin'),
      ];
      final live = [
        _mon(id: 'DP-1', descriptor: _twinA, label: 'Acme Twin'),
        _mon(id: 'DP-2', descriptor: _twinA, label: 'Acme Twin'),
      ];
      final pairs = OutputMatcher.pair(entries, live);
      expect(pairs.values.toSet(), hasLength(2),
          reason: 'each live output may be claimed once');
    });

    test('entries with no live partner are simply absent', () {
      final pairs = OutputMatcher.pair(
        [_mon(id: 'DP-1'), _mon(id: 'DP-2')],
        [_mon(id: 'DP-1')],
      );
      expect(pairs, {0: 0});
    });
  });
}
