import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guards the rule that a widget may choose *which* control it uses, but not
/// what that control looks like.
///
/// The concrete failure this exists to prevent: dropdowns, menus and dialogs
/// fell out of the app's visual language. They render into their own overlay,
/// so they inherit nothing from what was styled on the canvas or on a tile —
/// leaving them on Material defaults, or styling them at one call site, makes
/// them look like a different application. Every control is themed centrally
/// in lib/design/app_theme.dart instead.
///
/// The check is a ratchet, not a wall. The counts below are what each file
/// carried when the token layer landed; a file may shrink but never grow, and
/// a new file starts at zero. That turns "we should tidy this up some day"
/// into something the build enforces.
const Map<String, int> _allowedInlineStyling = {
  // Animated alphas — they ARE the pulse, so they cannot be static tokens.
  'widgets/identify_overlay.dart': 3,
  // Two accent alphas that vary with the tile's state.
  'widgets/monitor_tile.dart': 2,
  // Not a widget: it parses a colour out of the sway config, which is where
  // the accent comes from in the first place.
  'services/sway_theme.dart': 1,
  // One alpha on the guide colour, tuned against the canvas.
  'widgets/snap_lines_painter.dart': 1,
};

/// Literal colours, radii and text styles: the three ways a call site decides
/// its own appearance.
final RegExp _inlineStyling =
    RegExp(r'Color\(0x|BorderRadius\.circular\(|TextStyle\(|withValues\(alpha:');

void main() {
  test('no file styles itself more than its recorded baseline', () {
    final lib = Directory('lib');
    final offenders = <String, ({int found, int allowed})>{};

    for (final entity in lib.listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final rel = entity.path.substring('lib/'.length);
      // The design layer is where appearance is decided. That is its job.
      if (rel.startsWith('design/')) continue;

      final count = _inlineStyling
          .allMatches(entity.readAsStringSync())
          .length;
      final allowed = _allowedInlineStyling[rel] ?? 0;
      if (count > allowed) {
        offenders[rel] = (found: count, allowed: allowed);
      }
    }

    expect(
      offenders,
      isEmpty,
      reason: 'These files decide their own appearance beyond their baseline. '
          'Style through lib/design/app_theme.dart and the tokens instead, so '
          'the change reaches menus and dialogs too — they render in their own '
          'overlay and inherit nothing.\n'
          '${offenders.entries.map((e) => '  ${e.key}: '
              '${e.value.found} (allowed ${e.value.allowed})').join('\n')}',
    );
  });

  test('the baseline does not list files that no longer exist', () {
    // Otherwise a deleted file leaves a stale allowance that silently grants
    // budget to nothing.
    final missing = _allowedInlineStyling.keys
        .where((rel) => !File('lib/$rel').existsSync())
        .toList();
    expect(missing, isEmpty,
        reason: 'Remove these from the baseline: $missing');
  });

  test('the theme covers every overlay control family', () {
    // These are the ones that render outside the widget tree they were
    // written in, so a missing entry here is invisible until someone opens
    // the menu and sees Material's defaults.
    final theme = File('lib/design/app_theme.dart').readAsStringSync();
    for (final family in const [
      'menuTheme',
      'dropdownMenuTheme',
      'popupMenuTheme',
      'menuButtonTheme',
      'dialogTheme',
      'bottomSheetTheme',
      'tooltipTheme',
      'snackBarTheme',
    ]) {
      expect(theme, contains(family),
          reason: '$family is unthemed, so it will render as Material '
              'defaults in its own overlay');
    }
  });

  test('the corner radii are one decision, not a scale', () {
    // M10's angular pass. A 14px card corner beside a monitor tile was the
    // app disagreeing with itself about whether this is a precision
    // instrument or a phone; there is effectively one radius now, and the
    // reasoning lives in tokens.dart rather than in whichever widget was
    // written last.
    final tokens = File('lib/design/tokens.dart').readAsStringSync();
    final radii = RegExp(r'static const double (chip|control|screen|card|sheet) = (\d+);')
        .allMatches(tokens)
        .map((m) => int.parse(m.group(2)!))
        .toList();
    expect(radii, hasLength(5), reason: 'all five radii must be declared');
    expect(radii.every((r) => r <= 3), isTrue,
        reason: 'anything softer than a chamfer belongs to a different app: '
            'found $radii');
  });

  test('the seed-based colour scheme is gone', () {
    // ColorScheme.fromSeed derived every surface from Material's tonal
    // algorithm, which is why the app's colours were whatever the algorithm
    // produced rather than what was designed.
    final main = File('lib/main.dart')
        .readAsLinesSync()
        .where((l) => !l.trimLeft().startsWith('//'))
        .join('\n');
    expect(main, isNot(contains('ColorScheme.fromSeed(')));
  });
}
