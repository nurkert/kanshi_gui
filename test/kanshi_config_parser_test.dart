import 'package:flutter_test/flutter_test.dart';
import 'package:kanshi_gui/services/kanshi_config_parser.dart';

void main() {
  group('KanshiConfigParser.parse', () {
    test('parses a single quoted profile with one enabled output', () {
      const cfg = '''
profile 'Desk' {
    output 'Eizo CG279X 0' enable scale 1.00 mode 2560x1440@60Hz transform normal position 0,0
}
''';
      final profiles = KanshiConfigParser.parse(cfg);
      expect(profiles, hasLength(1));
      expect(profiles.first.name, equals('Desk'));
      expect(profiles.first.monitors, hasLength(1));
      final m = profiles.first.monitors.first;
      expect(m.id, equals('Eizo CG279X 0'));
      expect(m.width, equals(2560));
      expect(m.height, equals(1440));
      expect(m.refresh, equals(60));
      expect(m.scale, equals(1.0));
      expect(m.rotation, equals(0));
      expect(m.x, equals(0));
      expect(m.y, equals(0));
      expect(m.enabled, isTrue);
    });

    test('parses bare profile name (no quotes)', () {
      const cfg = '''
profile undocked {
    output 'eDP-1' enable scale 1.50 mode 1920x1080@60Hz transform normal position 0,0
}
''';
      final profiles = KanshiConfigParser.parse(cfg);
      expect(profiles, hasLength(1));
      expect(profiles.first.name, equals('undocked'));
    });

    test('parses opening brace on next line', () {
      const cfg = '''
profile 'foo'
{
    output 'eDP-1' enable scale 1.00 mode 1920x1080@60Hz transform normal position 0,0
}
''';
      final profiles = KanshiConfigParser.parse(cfg);
      expect(profiles, hasLength(1));
      expect(profiles.first.monitors, hasLength(1));
    });

    test('handles disabled outputs', () {
      const cfg = '''
profile 'X' {
    output 'eDP-1' disable
}
''';
      final m = KanshiConfigParser.parse(cfg).single.monitors.single;
      expect(m.enabled, isFalse);
    });

    test('rotates dimensions for transform 90', () {
      const cfg = '''
profile 'P' {
    output 'A' enable scale 1.00 mode 2560x1440@60Hz transform 90 position -200,0
}
''';
      final m = KanshiConfigParser.parse(cfg).single.monitors.single;
      expect(m.rotation, equals(90));
      // Rotated → width and height swap.
      expect(m.width, equals(1440));
      expect(m.height, equals(2560));
      expect(m.orientation, equals('portrait'));
      expect(m.x, equals(-200));
    });

    test('skips full-line comments and trailing comments', () {
      const cfg = '''
# top-level comment
profile 'P' {
    # inner comment
    output 'A' enable scale 1.00 mode 1920x1080@60Hz transform normal position 0,0  # trailing
}
''';
      final p = KanshiConfigParser.parse(cfg);
      expect(p, hasLength(1));
      expect(p.first.monitors, hasLength(1));
    });

    test('parses two profiles back to back', () {
      const cfg = '''
profile 'A' {
    output 'X' enable scale 1.00 mode 1920x1080@60Hz transform normal position 0,0
}

profile 'B' {
    output 'Y' enable scale 1.00 mode 2560x1440@60Hz transform normal position 0,0
}
''';
      final profiles = KanshiConfigParser.parse(cfg);
      expect(profiles.map((p) => p.name).toList(), equals(['A', 'B']));
    });

    test('tolerates exec lines containing braces inside strings', () {
      const cfg = '''
profile 'P' {
    output 'X' enable scale 1.00 mode 1920x1080@60Hz transform normal position 0,0
    exec swaymsg "workspace 1 output 'X'; workspace 1"
}
''';
      final profiles = KanshiConfigParser.parse(cfg);
      expect(profiles, hasLength(1));
      expect(profiles.first.monitors, hasLength(1));
    });

    test('returns empty list for empty content', () {
      expect(KanshiConfigParser.parse(''), isEmpty);
    });

    test('preserves quoted output names with spaces and special chars', () {
      const cfg = '''
profile 'P' {
    output 'Acme Studio Display 0x1234' enable scale 1.00 mode 1920x1080@60Hz transform normal position 0,0
}
''';
      final m = KanshiConfigParser.parse(cfg).single.monitors.single;
      expect(m.id, equals('Acme Studio Display 0x1234'));
    });
  });
}
