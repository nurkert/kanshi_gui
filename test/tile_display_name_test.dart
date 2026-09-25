import 'package:flutter_test/flutter_test.dart';
import 'package:kanshi_gui/widgets/monitor_tile.dart';

void main() {
  group('tileDisplayName', () {
    test('drops the region and legal form from an EDID make', () {
      expect(
        tileDisplayName(
            'InfoVision Optoelectronics (Kunshan) Co. Ltd 0x8C4D ABC123'),
        'InfoVision Optoelectronics',
      );
    });

    test('drops a trailing Inc. and Corporation', () {
      expect(tileDisplayName('Dell Inc. U2720Q 5KC0Q83'), 'Dell');
      expect(tileDisplayName('Sharp Corporation 0x14F9 X'), 'Sharp');
    });

    test('keeps a make with nothing to trim', () {
      expect(tileDisplayName('Lenovo Group Limited P27h-20 V90A'),
          'Lenovo Group');
      expect(tileDisplayName('Samsung U28E590'), 'Samsung U28E590');
    });

    test('never ends up empty', () {
      expect(tileDisplayName('Ltd. X Y'), 'Ltd.');
      expect(tileDisplayName('eDP-1'), 'eDP-1');
    });
  });
}
